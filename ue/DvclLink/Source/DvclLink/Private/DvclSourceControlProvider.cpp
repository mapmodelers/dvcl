#include "DvclSourceControlProvider.h"

#include "DvclSourceControlState.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformTime.h"
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
	return Op == "Connect" || Op == "UpdateStatus" || Op == "CheckOut" || Op == "MarkForAdd" || Op == "Delete";
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
		const FText Message = FText::Format(LOCTEXT("InDvcl", "'{0}': do it in the dvcl window for now (dvcl revision control shows states only)."), FText::FromName(Op));
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
