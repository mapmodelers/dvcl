#include "DvclSourceControlProvider.h"

#include "DvclSourceControlChangelist.h"
#include "DvclSourceControlState.h"
#include "Dom/JsonObject.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformProcess.h"
#include "HAL/PlatformTime.h"
#include "ISourceControlModule.h"
#include "Logging/MessageLog.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Misc/ScopedSlowTask.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "SourceControlHelpers.h"
#include "SourceControlOperations.h"
#if SOURCE_CONTROL_WITH_SLATE
#include "Widgets/Text/STextBlock.h"
#endif

#define LOCTEXT_NAMESPACE "DvclSourceControl"

namespace
{
	// the workspace dvcl works in: the first folder above the project holding .dvcl
	FString FindDvclRoot()
	{
		FString Dir = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir());
		FPaths::NormalizeDirectoryName(Dir);
		for (int32 Guard = 0; Guard < 64 && !Dir.IsEmpty(); ++Guard)
		{
			if (IFileManager::Get().DirectoryExists(*(Dir / TEXT(".dvcl"))))
			{
				return Dir;
			}
			const FString Parent = FPaths::GetPath(Dir);
			if (Parent.IsEmpty() || Parent == Dir)
			{
				break;
			}
			Dir = Parent;
		}
		return FString();
	}
}

FString FDvclSourceControlProvider::Key(const FString& File)
{
	FString Full = FPaths::ConvertRelativePathToFull(File);
	FPaths::NormalizeFilename(Full);
	return Full.ToLower();
}

int32 FDvclSourceControlProvider::ClId(const FSourceControlChangelistPtr& InChangelist)
{
	if (!InChangelist.IsValid() || InChangelist->IsDefault())
	{
		return 0;
	}
	const FString Id = InChangelist->GetIdentifier();
	return Id.IsNumeric() ? FCString::Atoi(*Id) : 0;
}

void FDvclSourceControlProvider::Init(bool bForceConnection)
{
	Root = FindDvclRoot();
	PendingFile = Root.IsEmpty() ? FString() : (Root / TEXT(".dvcl/pending.tsv"));
	ClFile = Root.IsEmpty() ? FString() : (Root / TEXT(".dvcl/changelists.json"));
	PendingStamp = FDateTime::MinValue();
	ClStamp = FDateTime::MinValue();
	Reload(true);
}

void FDvclSourceControlProvider::Close()
{
	Pending.Reset();
	ClStates.Reset();
	ClOrder.Reset();
	Owner.Reset();
	Done.Reset();
}

const FName& FDvclSourceControlProvider::GetName() const
{
	static const FName ProviderName("dvcl");
	return ProviderName;
}

FText FDvclSourceControlProvider::GetStatusText() const
{
	if (Root.IsEmpty())
	{
		return LOCTEXT("NoRoot", "No dvcl workspace above this project (open the workspace in dvcl once).");
	}
	return FText::Format(LOCTEXT("Status", "dvcl workspace {0}: {1} pending file(s) in {2} changelist(s). States follow the dvcl window (keep it open). Revert, submit and changelists run dvcl."),
		FText::FromString(Root), FText::AsNumber(Pending.Num()), FText::AsNumber(ClOrder.Num()));
}

TMap<ISourceControlProvider::EStatus, FString> FDvclSourceControlProvider::GetStatus() const
{
	TMap<EStatus, FString> Result;
	Result.Add(EStatus::Enabled, TEXT("Yes"));
	Result.Add(EStatus::Connected, Root.IsEmpty() ? TEXT("No") : TEXT("Yes (offline, local)"));
	Result.Add(EStatus::WorkspacePath, Root);
	return Result;
}

void FDvclSourceControlProvider::ReadChangelists()
{
	// the same objects are kept from one read to the next: Unreal's Changelists window knows its rows
	// by these objects, a new object would drop the selection
	TMap<int32, TSharedRef<FDvclChangelistState, ESPMode::ThreadSafe>> Old = MoveTemp(ClStates);
	ClStates.Reset();
	ClOrder.Reset();
	Owner.Reset();
	auto Keep = [this, &Old](int32 Id, const FString& Name, const FString& Description)
	{
		const TSharedRef<FDvclChangelistState, ESPMode::ThreadSafe>* Found = Old.Find(Id);
		TSharedRef<FDvclChangelistState, ESPMode::ThreadSafe> State = Found != nullptr ? *Found : MakeShared<FDvclChangelistState, ESPMode::ThreadSafe>(Id, Name, Description);
		State->Name = Name;
		State->Description = Description;
		State->Files.Reset();
		ClStates.Add(Id, State);
		ClOrder.Add(Id);
	};
	Keep(0, FString(TEXT("default")), FString());
	FString Text;
	if (ClFile.IsEmpty() || !FFileHelper::LoadFileToString(Text, *ClFile))
	{
		return;
	}
	TSharedPtr<FJsonObject> Json;
	const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
	if (!FJsonSerializer::Deserialize(Reader, Json) || !Json.IsValid())
	{
		return;
	}
	const TArray<TSharedPtr<FJsonValue>>* List = nullptr;
	if (!Json->TryGetArrayField(TEXT("changelists"), List) || List == nullptr)
	{
		return;
	}
	for (const TSharedPtr<FJsonValue>& Value : *List)
	{
		const TSharedPtr<FJsonObject> Cl = Value.IsValid() ? Value->AsObject() : nullptr;
		if (!Cl.IsValid())
		{
			continue;
		}
		int32 Id = 0;
		Cl->TryGetNumberField(TEXT("id"), Id);
		if (Id <= 0 || ClStates.Contains(Id))
		{
			continue;
		}
		FString Name;
		FString Description;
		Cl->TryGetStringField(TEXT("name"), Name);
		Cl->TryGetStringField(TEXT("desc"), Description);
		Keep(Id, Name, Description);
		const TArray<TSharedPtr<FJsonValue>>* Files = nullptr;
		if (Cl->TryGetArrayField(TEXT("files"), Files) && Files != nullptr)
		{
			for (const TSharedPtr<FJsonValue>& FileValue : *Files)
			{
				FString File;
				if (FileValue.IsValid() && FileValue->TryGetString(File) && !File.IsEmpty())
				{
					Owner.Add(Key(Root / File), Id);
				}
			}
		}
	}
}

bool FDvclSourceControlProvider::Reload(bool bForce)
{
	if (PendingFile.IsEmpty())
	{
		return false;
	}
	const FDateTime Stamp = IFileManager::Get().GetTimeStamp(*PendingFile);
	const FDateTime CStamp = IFileManager::Get().GetTimeStamp(*ClFile);
	if (!bForce && Stamp == PendingStamp && CStamp == ClStamp)
	{
		return false;
	}
	PendingStamp = Stamp;
	ClStamp = CStamp;
	// the changelists file says which changelist owns a file; the pending list says what changed
	ReadChangelists();
	// unchanged files keep their state object too (same reason)
	TMap<FString, TSharedRef<FDvclSourceControlState, ESPMode::ThreadSafe>> OldPending = MoveTemp(Pending);
	Pending.Reset();
	TArray<FString> Lines;
	if (FFileHelper::LoadFileToStringArray(Lines, *PendingFile))
	{
		for (const FString& Line : Lines)
		{
			if (Line.IsEmpty() || Line.StartsWith(TEXT("#")))
			{
				continue;
			}
			TArray<FString> Parts;
			Line.ParseIntoArray(Parts, TEXT("\t"), false);
			if (Parts.Num() < 2 || Parts[0].IsEmpty() || Parts[1].IsEmpty())
			{
				continue;
			}
			FString Full = Root / Parts[1];
			FPaths::NormalizeFilename(Full);
			const FString FileKey = Key(Full);
			int32 Id = Owner.FindRef(FileKey);
			if (!ClStates.Contains(Id))
			{
				Id = 0;
			}
			const TSharedRef<FDvclChangelistState, ESPMode::ThreadSafe>& Cl = ClStates.FindChecked(Id);
			const TCHAR Kind = FChar::ToUpper(Parts[0][0]);
			const FString Label = Cl->GetDisplayText().ToString();
			const TSharedRef<FDvclSourceControlState, ESPMode::ThreadSafe>* Was = OldPending.Find(FileKey);
			const TSharedRef<FDvclSourceControlState, ESPMode::ThreadSafe> State = (Was != nullptr && (*Was)->Kind == Kind && (*Was)->Changelist == Label) ? *Was : MakeShared<FDvclSourceControlState, ESPMode::ThreadSafe>(Full, Kind, Label);
			Pending.Add(FileKey, State);
			Cl->Files.Add(State);
		}
	}
	return true;
}

TArray<FString> FDvclSourceControlProvider::FilesOf(int32 Id) const
{
	TArray<FString> Result;
	if (const TSharedRef<FDvclChangelistState, ESPMode::ThreadSafe>* Cl = ClStates.Find(Id))
	{
		for (const FSourceControlStateRef& State : (*Cl)->Files)
		{
			Result.Add(State->GetFilename());
		}
	}
	return Result;
}

ECommandResult::Type FDvclSourceControlProvider::GetState(const TArray<FString>& InFiles, TArray<FSourceControlStateRef>& OutState, EStateCacheUsage::Type InStateCacheUsage)
{
	if (InStateCacheUsage == EStateCacheUsage::ForceUpdate)
	{
		Reload(false);
	}
	for (const FString& File : SourceControlHelpers::AbsoluteFilenames(InFiles))
	{
		if (const TSharedRef<FDvclSourceControlState, ESPMode::ThreadSafe>* Found = Pending.Find(Key(File)))
		{
			OutState.Add(*Found);
		}
		else
		{
			FString Full = File;
			FPaths::NormalizeFilename(Full);
			OutState.Add(MakeShared<FDvclSourceControlState, ESPMode::ThreadSafe>(Full, TCHAR(0), FString()));
		}
	}
	return ECommandResult::Succeeded;
}

ECommandResult::Type FDvclSourceControlProvider::GetState(const TArray<FSourceControlChangelistRef>& InChangelists, TArray<FSourceControlChangelistStateRef>& OutState, EStateCacheUsage::Type InStateCacheUsage)
{
	if (InStateCacheUsage == EStateCacheUsage::ForceUpdate)
	{
		Reload(false);
	}
	for (const FSourceControlChangelistRef& Changelist : InChangelists)
	{
		if (const TSharedRef<FDvclChangelistState, ESPMode::ThreadSafe>* Found = ClStates.Find(ClId(Changelist)))
		{
			OutState.Add(*Found);
		}
	}
	return ECommandResult::Succeeded;
}

TArray<FSourceControlChangelistRef> FDvclSourceControlProvider::GetChangelists(EStateCacheUsage::Type InStateCacheUsage)
{
	if (InStateCacheUsage == EStateCacheUsage::ForceUpdate)
	{
		Reload(false);
	}
	TArray<FSourceControlChangelistRef> Result;
	for (const int32 Id : ClOrder)
	{
		Result.Add(MakeShared<FDvclChangelist, ESPMode::ThreadSafe>(Id));
	}
	return Result;
}

TArray<FSourceControlStateRef> FDvclSourceControlProvider::GetCachedStateByPredicate(TFunctionRef<bool(const FSourceControlStateRef&)> Predicate) const
{
	TArray<FSourceControlStateRef> Result;
	for (const auto& Item : Pending)
	{
		FSourceControlStateRef State = Item.Value;
		if (Predicate(State))
		{
			Result.Add(State);
		}
	}
	return Result;
}

FDelegateHandle FDvclSourceControlProvider::RegisterSourceControlStateChanged_Handle(const FSourceControlStateChanged::FDelegate& SourceControlStateChanged)
{
	return OnStateChanged.Add(SourceControlStateChanged);
}

void FDvclSourceControlProvider::UnregisterSourceControlStateChanged_Handle(FDelegateHandle Handle)
{
	OnStateChanged.Remove(Handle);
}

bool FDvclSourceControlProvider::CanExecuteOperation(const FSourceControlOperationRef& InOperation) const
{
	const FName Op = InOperation->GetName();
	return Op == "Connect" || Op == "UpdateStatus" || Op == "CheckOut" || Op == "MarkForAdd" || Op == "Delete" || Op == "Revert" || Op == "CheckIn"
		|| Op == "RevertUnchanged" || Op == "UpdateChangelistsStatus" || Op == "NewChangelist" || Op == "DeleteChangelist" || Op == "EditChangelist" || Op == "MoveToChangelist";
}

ECommandResult::Type FDvclSourceControlProvider::Execute(const FSourceControlOperationRef& InOperation, FSourceControlChangelistPtr InChangelist, const TArray<FString>& InFiles, EConcurrency::Type InConcurrency, const FSourceControlOperationComplete& InOperationCompleteDelegate)
{
	const FName Op = InOperation->GetName();
	ECommandResult::Type Result = ECommandResult::Succeeded;
	if (Op == "Connect")
	{
		if (Root.IsEmpty())
		{
			Init(true);
		}
		if (Root.IsEmpty())
		{
			InOperation->AddErrorMessge(GetStatusText());
			Result = ECommandResult::Failed;
		}
	}
	else if (Op == "UpdateStatus" || Op == "UpdateChangelistsStatus")
	{
		// Unreal asks this every few seconds: reread only if dvcl changed its files
		if (Reload(false))
		{
			OnStateChanged.Broadcast();
		}
	}
	else if (Op == "CheckOut" || Op == "MarkForAdd" || Op == "RevertUnchanged")
	{
		// Diversion sees every change by itself, and a file without change is not pending: nothing to do
	}
	else if (Op == "Revert")
	{
		// only files with a change to undo (Unreal also reverts before deleting an asset: unchanged and
		// new files have nothing to revert, so that delete stays instant)
		Reload(false);
		TArray<FString> ToRevert;
		for (const FString& File : SourceControlHelpers::AbsoluteFilenames(InFiles))
		{
			const TSharedRef<FDvclSourceControlState, ESPMode::ThreadSafe>* Found = Pending.Find(Key(File));
			if (Found != nullptr && (*Found)->CanRevert())
			{
				ToRevert.Add(File);
			}
		}
		if (ToRevert.Num() > 0)
		{
			Result = RunFilesCommand(TEXT("revert-files"), ToRevert, FString(), LOCTEXT("Reverting", "dvcl: reverting (online for this only, then back offline)..."), InOperation);
		}
	}
	else if (Op == "CheckIn")
	{
		TSharedRef<FCheckIn, ESPMode::ThreadSafe> CheckIn = StaticCastSharedRef<FCheckIn>(InOperation);
		const FString Description = CheckIn->GetDescription().ToString().TrimStartAndEnd();
		Reload(false);
		if (Description.IsEmpty())
		{
			InOperation->AddErrorMessge(LOCTEXT("NoDescription", "dvcl: a description is required to submit."));
			Result = ECommandResult::Failed;
		}
		else if (InFiles.Num() == 0 && InChangelist.IsValid())
		{
			// a whole changelist (Changelists window): dvcl submits that changelist with this description
			const int32 Id = ClId(InChangelist);
			const FString Message = WriteMessage(Description);
			const FText What = LOCTEXT("SubmittingCl", "dvcl: submitting the changelist (waits for Diversion's upload, then back offline)...");
			if (Id == 0)
			{
				Result = RunCommand(FString::Printf(TEXT("submit default \"@%s\" -y"), *Message), What, InOperation);
			}
			else
			{
				Result = RunCommand(FString::Printf(TEXT("desc %d \"@%s\""), Id, *Message), LOCTEXT("Describing", "dvcl: description..."), InOperation);
				if (Result == ECommandResult::Succeeded)
				{
					Result = RunCommand(FString::Printf(TEXT("submit %d -y"), Id), What, InOperation);
				}
			}
		}
		else
		{
			// files (Submit Content): only files of one changelist, so a submit never mixes changelists
			TSet<int32> Ids;
			for (const FString& File : SourceControlHelpers::AbsoluteFilenames(InFiles))
			{
				Ids.Add(Owner.FindRef(Key(File)));
			}
			if (Ids.Num() > 1)
			{
				InOperation->AddErrorMessge(FText::Format(LOCTEXT("MixedCls", "dvcl: these files belong to {0} changelists. Submit one changelist at a time (Window > Revision Control > Changelists, or the dvcl window)."), FText::AsNumber(Ids.Num())));
				Result = ECommandResult::Failed;
			}
			else
			{
				Result = RunFilesCommand(TEXT("submit-files"), InFiles, Description, LOCTEXT("Submitting", "dvcl: submitting (waits for Diversion's upload, then back offline)..."), InOperation);
			}
		}
		if (Result == ECommandResult::Succeeded)
		{
			CheckIn->SetSuccessMessage(LOCTEXT("Submitted", "Submitted with dvcl."));
		}
	}
	else if (Op == "NewChangelist")
	{
		TSharedRef<FNewChangelist, ESPMode::ThreadSafe> NewCl = StaticCastSharedRef<FNewChangelist>(InOperation);
		FString Description = NewCl->GetDescription().ToString().TrimStartAndEnd();
		if (Description.IsEmpty())
		{
			Description = TEXT("new changelist");
		}
		int32 Before = 0;
		for (const int32 Id : ClOrder)
		{
			Before = FMath::Max(Before, Id);
		}
		Result = RunCommand(FString::Printf(TEXT("new \"@%s\""), *WriteMessage(Description)), LOCTEXT("Creating", "dvcl: new changelist..."), InOperation);
		int32 After = 0;
		for (const int32 Id : ClOrder)
		{
			After = FMath::Max(After, Id);
		}
		if (Result == ECommandResult::Succeeded && After > Before)
		{
			NewCl->SetNewChangelist(MakeShared<FDvclChangelist, ESPMode::ThreadSafe>(After));
			if (InFiles.Num() > 0)
			{
				const FString ListFile = Root / TEXT(".dvcl/ue-files.txt");
				FFileHelper::SaveStringArrayToFile(SourceControlHelpers::AbsoluteFilenames(InFiles), *ListFile, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
				Result = RunCommand(FString::Printf(TEXT("add %d \"@%s\""), After, *ListFile), LOCTEXT("Moving", "dvcl: moving files..."), InOperation);
			}
		}
	}
	else if (Op == "DeleteChangelist")
	{
		const int32 Id = ClId(InChangelist);
		if (Id == 0)
		{
			InOperation->AddErrorMessge(LOCTEXT("NoDeleteDefault", "dvcl: the default changelist cannot be deleted."));
			Result = ECommandResult::Failed;
		}
		else
		{
			Result = RunCommand(FString::Printf(TEXT("delete %d"), Id), LOCTEXT("Deleting", "dvcl: deleting the changelist (its files go to default)..."), InOperation);
		}
	}
	else if (Op == "EditChangelist")
	{
		const int32 Id = ClId(InChangelist);
		TSharedRef<FEditChangelist, ESPMode::ThreadSafe> Edit = StaticCastSharedRef<FEditChangelist>(InOperation);
		const FString Description = Edit->GetDescription().ToString().TrimStartAndEnd();
		if (Id == 0)
		{
			InOperation->AddErrorMessge(LOCTEXT("NoEditDefault", "dvcl: the default changelist has no description (make a new changelist)."));
			Result = ECommandResult::Failed;
		}
		else
		{
			Result = RunCommand(FString::Printf(TEXT("desc %d \"@%s\""), Id, *WriteMessage(Description)), LOCTEXT("Describing", "dvcl: description..."), InOperation);
		}
	}
	else if (Op == "MoveToChangelist")
	{
		const int32 Id = ClId(InChangelist);
		TArray<FString> Files = SourceControlHelpers::AbsoluteFilenames(InFiles);
		if (Files.Num() > 0)
		{
			const FString ListFile = Root / TEXT(".dvcl/ue-files.txt");
			FFileHelper::SaveStringArrayToFile(Files, *ListFile, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
			const FString Args = Id == 0 ? FString::Printf(TEXT("remove \"@%s\""), *ListFile) : FString::Printf(TEXT("add %d \"@%s\""), Id, *ListFile);
			Result = RunCommand(Args, LOCTEXT("Moving", "dvcl: moving files..."), InOperation);
		}
	}
	else if (Op == "Delete")
	{
		// Diversion sees the file gone; dvcl lists it as deleted
		for (const FString& File : SourceControlHelpers::AbsoluteFilenames(InFiles))
		{
			IFileManager::Get().Delete(*File, false, true, true);
		}
	}
	else
	{
		const FText Message = FText::Format(LOCTEXT("InDvcl", "'{0}': not in Unreal yet, use the dvcl window."), FText::FromName(Op));
		FMessageLog("SourceControl").Warning(Message);
		InOperation->AddErrorMessge(Message);
		Result = ECommandResult::Failed;
	}
	if (InConcurrency == EConcurrency::Asynchronous)
	{
		Done.Emplace(InOperation, Result, InOperationCompleteDelegate);
		return ECommandResult::Succeeded;
	}
	InOperationCompleteDelegate.ExecuteIfBound(InOperation, Result);
	return Result;
}

FString FDvclSourceControlProvider::WriteMessage(const FString& Text) const
{
	const FString MessageFile = Root / TEXT(".dvcl/ue-message.txt");
	FFileHelper::SaveStringToFile(Text, *MessageFile, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
	return MessageFile;
}

ECommandResult::Type FDvclSourceControlProvider::RunFilesCommand(const FString& Command, const TArray<FString>& InFiles, const FString& Message, const FText& What, const FSourceControlOperationRef& InOperation)
{
	if (Root.IsEmpty())
	{
		InOperation->AddErrorMessge(GetStatusText());
		return ECommandResult::Failed;
	}
	TArray<FString> Files = SourceControlHelpers::AbsoluteFilenames(InFiles);
	if (Files.Num() == 0)
	{
		InOperation->AddErrorMessge(LOCTEXT("NoFiles", "dvcl: no file given."));
		return ECommandResult::Failed;
	}
	const FString ListFile = Root / TEXT(".dvcl/ue-files.txt");
	FFileHelper::SaveStringArrayToFile(Files, *ListFile, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
	FString Args = Command + TEXT(" \"@") + ListFile + TEXT("\"");
	if (!Message.IsEmpty())
	{
		Args += TEXT(" \"@") + WriteMessage(Message) + TEXT("\"");
	}
	Args += TEXT(" -y");
	return RunCommand(Args, What, InOperation);
}

ECommandResult::Type FDvclSourceControlProvider::RunCommand(const FString& Args, const FText& What, const FSourceControlOperationRef& InOperation)
{
	if (Root.IsEmpty())
	{
		InOperation->AddErrorMessge(GetStatusText());
		return ECommandResult::Failed;
	}
	FString Log;
	const bool bOk = RunDvcl(Args, What, Log);
	// files or changelists changed: states from dvcl's files (written by the command)
	Reload(true);
	OnStateChanged.Broadcast();
	if (!bOk)
	{
		// the last lines of dvcl's output say why
		TArray<FString> Lines;
		Log.ParseIntoArrayLines(Lines);
		const int32 First = FMath::Max(0, Lines.Num() - 8);
		FString Tail;
		for (int32 i = First; i < Lines.Num(); ++i)
		{
			Tail += Lines[i].TrimEnd() + TEXT("\n");
		}
		const FString Command = Args.Left(Args.Find(TEXT(" ")) > 0 ? Args.Find(TEXT(" ")) : Args.Len());
		InOperation->AddErrorMessge(FText::Format(LOCTEXT("DvclFailed", "dvcl {0} failed:\n{1}"), FText::FromString(Command), FText::FromString(Tail)));
		return ECommandResult::Failed;
	}
	return ECommandResult::Succeeded;
}

bool FDvclSourceControlProvider::RunDvcl(const FString& Args, const FText& What, FString& OutLog) const
{
	FString Tool;
	if (!FFileHelper::LoadFileToString(Tool, *(Root / TEXT(".dvcl/tool.txt"))))
	{
		OutLog = TEXT("dvcl not found: open this workspace in dvcl once (it writes .dvcl/tool.txt).");
		return false;
	}
	Tool.TrimStartAndEndInline();
	const FString Script = Tool / TEXT("src/dvcl-cli.ps1");
	if (!FPaths::FileExists(Script))
	{
		OutLog = FString::Printf(TEXT("dvcl not found at %s (reinstall dvcl, then open the workspace in it once)."), *Tool);
		return false;
	}
	const FString Params = FString::Printf(TEXT("-NoProfile -ExecutionPolicy Bypass -File \"%s\" %s"), *Script, *Args);
	void* ReadPipe = nullptr;
	void* WritePipe = nullptr;
	FPlatformProcess::CreatePipe(ReadPipe, WritePipe);
	FProcHandle Proc = FPlatformProcess::CreateProc(TEXT("powershell.exe"), *Params, false, true, true, nullptr, 0, *Root, WritePipe, nullptr);
	if (!Proc.IsValid())
	{
		FPlatformProcess::ClosePipe(ReadPipe, WritePipe);
		OutLog = TEXT("powershell.exe could not be started.");
		return false;
	}
	// progress dialog with dvcl's last line (Unreal stays drawn while dvcl works)
	FScopedSlowTask Task(0.f, What);
	Task.MakeDialog(false);
	FString Last;
	while (FPlatformProcess::IsProcRunning(Proc))
	{
		const FString Chunk = FPlatformProcess::ReadPipe(ReadPipe);
		if (!Chunk.IsEmpty())
		{
			OutLog += Chunk;
			TArray<FString> Lines;
			Chunk.ParseIntoArrayLines(Lines);
			if (Lines.Num() > 0)
			{
				Last = Lines.Last().TrimStartAndEnd();
			}
		}
		Task.EnterProgressFrame(0.f, Last.IsEmpty() ? What : FText::FromString(Last));
		FPlatformProcess::Sleep(0.1f);
	}
	OutLog += FPlatformProcess::ReadPipe(ReadPipe);
	int32 Code = -1;
	FPlatformProcess::GetProcReturnCode(Proc, &Code);
	FPlatformProcess::CloseProc(Proc);
	FPlatformProcess::ClosePipe(ReadPipe, WritePipe);
	return Code == 0;
}

void FDvclSourceControlProvider::Tick()
{
	if (Done.Num() > 0)
	{
		TArray<TTuple<FSourceControlOperationRef, ECommandResult::Type, FSourceControlOperationComplete>> Ready = MoveTemp(Done);
		Done.Reset();
		for (const auto& Item : Ready)
		{
			Item.Get<2>().ExecuteIfBound(Item.Get<0>(), Item.Get<1>());
		}
	}
	const double Now = FPlatformTime::Seconds();
	if (Now < NextCheck)
	{
		return;
	}
	NextCheck = Now + 2.0;
	// dvcl rewrote its list or its changelists (save, revert, unshelve, move...): states follow
	if (Reload(false))
	{
		OnStateChanged.Broadcast();
	}
}

#if SOURCE_CONTROL_WITH_SLATE
TSharedRef<SWidget> FDvclSourceControlProvider::MakeSettingsWidget() const
{
	return SNew(STextBlock).AutoWrapText(true).Text(GetStatusText());
}
#endif

#undef LOCTEXT_NAMESPACE
