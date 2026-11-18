#include "DvclSourceControlProvider.h"

#include "DvclSourceControlState.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformProcess.h"
#include "HAL/PlatformTime.h"
#include "Misc/ScopedSlowTask.h"
#include "ISourceControlModule.h"
#include "Logging/MessageLog.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
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

void FDvclSourceControlProvider::Init(bool bForceConnection)
{
	Root = FindDvclRoot();
	PendingFile = Root.IsEmpty() ? FString() : (Root / TEXT(".dvcl/pending.tsv"));
	PendingStamp = FDateTime::MinValue();
	Reload(true);
}

void FDvclSourceControlProvider::Close()
{
	Pending.Reset();
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
	return FText::Format(LOCTEXT("Status", "dvcl workspace {0}: {1} pending file(s). States follow the dvcl window (keep it open); check in / revert in dvcl."),
		FText::FromString(Root), FText::AsNumber(Pending.Num()));
}

TMap<ISourceControlProvider::EStatus, FString> FDvclSourceControlProvider::GetStatus() const
{
	TMap<EStatus, FString> Result;
	Result.Add(EStatus::Enabled, TEXT("Yes"));
	Result.Add(EStatus::Connected, Root.IsEmpty() ? TEXT("No") : TEXT("Yes (offline, local)"));
	Result.Add(EStatus::WorkspacePath, Root);
	return Result;
}

bool FDvclSourceControlProvider::Reload(bool bForce)
{
	if (PendingFile.IsEmpty())
	{
		return false;
	}
	const FDateTime Stamp = IFileManager::Get().GetTimeStamp(*PendingFile);
	if (!bForce && Stamp == PendingStamp)
	{
		return false;
	}
	PendingStamp = Stamp;
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
			const FString Cl = Parts.Num() > 2 ? Parts[2] : FString(TEXT("default"));
			Pending.Add(Key(Full), MakeShared<FDvclSourceControlState, ESPMode::ThreadSafe>(Full, FChar::ToUpper(Parts[0][0]), Cl));
		}
	}
	return true;
}

ECommandResult::Type FDvclSourceControlProvider::GetState(const TArray<FString>& InFiles, TArray<FSourceControlStateRef>& OutState, EStateCacheUsage::Type InStateCacheUsage)
{
	if (InStateCacheUsage == EStateCacheUsage::ForceUpdate)
	{
		Reload(true);
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
	return Op == "Connect" || Op == "UpdateStatus" || Op == "CheckOut" || Op == "MarkForAdd" || Op == "Delete" || Op == "Revert" || Op == "CheckIn";
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
	else if (Op == "UpdateStatus")
	{
		Reload(true);
		OnStateChanged.Broadcast();
	}
	else if (Op == "CheckOut" || Op == "MarkForAdd")
	{
		// Diversion sees every change by itself: nothing to do
	}
	else if (Op == "Revert")
	{
		Result = RunFilesCommand(TEXT("revert-files"), InFiles, FString(), LOCTEXT("Reverting", "dvcl: reverting (online for this only, then back offline)..."), InOperation);
	}
	else if (Op == "CheckIn")
	{
		TSharedRef<FCheckIn, ESPMode::ThreadSafe> CheckIn = StaticCastSharedRef<FCheckIn>(InOperation);
		const FString Description = CheckIn->GetDescription().ToString().TrimStartAndEnd();
		if (Description.IsEmpty())
		{
			InOperation->AddErrorMessge(LOCTEXT("NoDescription", "dvcl: a description is required to submit."));
			Result = ECommandResult::Failed;
		}
		else
		{
			Result = RunFilesCommand(TEXT("submit-files"), InFiles, Description, LOCTEXT("Submitting", "dvcl: submitting (waits for Diversion's upload, then back offline)..."), InOperation);
			if (Result == ECommandResult::Succeeded)
			{
				CheckIn->SetSuccessMessage(LOCTEXT("Submitted", "Submitted with dvcl."));
			}
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
		InOperation->AddErrorMessge(LOCTEXT("NoFiles", "dvcl: no file given (changelists from Unreal come later: use the dvcl window)."));
		return ECommandResult::Failed;
	}
	const FString ListFile = Root / TEXT(".dvcl/ue-files.txt");
	FFileHelper::SaveStringArrayToFile(Files, *ListFile, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
	FString Args = Command + TEXT(" \"@") + ListFile + TEXT("\"");
	if (!Message.IsEmpty())
	{
		const FString MessageFile = Root / TEXT(".dvcl/ue-message.txt");
		FFileHelper::SaveStringToFile(Message, *MessageFile, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
		Args += TEXT(" \"@") + MessageFile + TEXT("\"");
	}
	Args += TEXT(" -y");
	FString Log;
	const bool bOk = RunDvcl(Args, What, Log);
	// the files changed: states from dvcl's new list (written by the command)
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
	// dvcl rewrote its list (save, revert, unshelve, move to another changelist...): states follow
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
