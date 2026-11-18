// "dvcl" in Unreal's revision control: file states (modified / added / deleted, changelist) read from
// the list dvcl keeps in the workspace (.dvcl\pending.tsv), offline, no login, no check-out prompts.
// Phase 1: states only; check in / revert / sync stay in dvcl.
#pragma once

#include "CoreMinimal.h"
#include "ISourceControlProvider.h"

class FDvclSourceControlState;

class FDvclSourceControlProvider : public ISourceControlProvider
{
public:
	virtual void Init(bool bForceConnection = true) override;
	virtual void Close() override;
	virtual FText GetStatusText() const override;
	virtual TMap<EStatus, FString> GetStatus() const override;
	virtual bool IsEnabled() const override { return true; }
	virtual bool IsAvailable() const override { return !Root.IsEmpty(); }
	virtual const FName& GetName() const override;
	virtual bool QueryStateBranchConfig(const FString& ConfigSrc, const FString& ConfigDest) override { return false; }
	virtual void RegisterStateBranches(const TArray<FString>& BranchNames, const FString& ContentRoot) override {}
	virtual int32 GetStateBranchIndex(const FString& BranchName) const override { return INDEX_NONE; }
	virtual bool GetStateBranchAtIndex(int32 BranchIndex, FString& OutBranchName) const override { return false; }
	virtual ECommandResult::Type GetState(const TArray<FString>& InFiles, TArray<FSourceControlStateRef>& OutState, EStateCacheUsage::Type InStateCacheUsage) override;
	virtual ECommandResult::Type GetState(const TArray<FSourceControlChangelistRef>& InChangelists, TArray<FSourceControlChangelistStateRef>& OutState, EStateCacheUsage::Type InStateCacheUsage) override { return ECommandResult::Failed; }
	virtual TArray<FSourceControlStateRef> GetCachedStateByPredicate(TFunctionRef<bool(const FSourceControlStateRef&)> Predicate) const override;
	virtual FDelegateHandle RegisterSourceControlStateChanged_Handle(const FSourceControlStateChanged::FDelegate& SourceControlStateChanged) override;
	virtual void UnregisterSourceControlStateChanged_Handle(FDelegateHandle Handle) override;
	virtual ECommandResult::Type Execute(const FSourceControlOperationRef& InOperation, FSourceControlChangelistPtr InChangelist, const TArray<FString>& InFiles, EConcurrency::Type InConcurrency = EConcurrency::Synchronous, const FSourceControlOperationComplete& InOperationCompleteDelegate = FSourceControlOperationComplete()) override;
	virtual bool CanExecuteOperation(const FSourceControlOperationRef& InOperation) const override;
	virtual bool CanCancelOperation(const FSourceControlOperationRef& InOperation) const override { return false; }
	virtual void CancelOperation(const FSourceControlOperationRef& InOperation) override {}
	virtual bool UsesLocalReadOnlyState() const override { return false; }
	virtual bool UsesChangelists() const override { return false; }
	virtual bool UsesUncontrolledChangelists() const override { return false; }
	virtual bool UsesCheckout() const override { return false; }
	virtual bool UsesFileRevisions() const override { return false; }
	virtual bool UsesSnapshots() const override { return false; }
	virtual bool UsesSoftRevertOnDelete() const override { return false; }
	virtual bool AllowsDiffAgainstDepot() const override { return false; }
	virtual TOptional<bool> HasChangesToSync() const override { return TOptional<bool>(); }
	virtual TOptional<bool> HasChangesToCheckIn() const override { return TOptional<bool>(Pending.Num() > 0); }
	virtual void Tick() override;
	virtual TArray<TSharedRef<class ISourceControlLabel>> GetLabels(const FString& InMatchingSpec) const override { return TArray<TSharedRef<class ISourceControlLabel>>(); }
	virtual TArray<FSourceControlChangelistRef> GetChangelists(EStateCacheUsage::Type InStateCacheUsage) override { return TArray<FSourceControlChangelistRef>(); }
#if SOURCE_CONTROL_WITH_SLATE
	virtual TSharedRef<class SWidget> MakeSettingsWidget() const override;
#endif

private:
	// re-reads .dvcl\pending.tsv if it changed (or always); true = the states changed
	bool Reload(bool bForce);
	// runs dvcl's command line on these files (revert-files / submit-files), with a progress dialog;
	// errors go to the operation. Message: the submit description ('' = none).
	ECommandResult::Type RunFilesCommand(const FString& Command, const TArray<FString>& InFiles, const FString& Message, const FText& What, const FSourceControlOperationRef& InOperation);
	bool RunDvcl(const FString& Args, const FText& What, FString& OutLog) const;
	static FString Key(const FString& File);

	FString Root;
	FString PendingFile;
	FDateTime PendingStamp;
	double NextCheck = 0.0;
	TMap<FString, TSharedRef<FDvclSourceControlState, ESPMode::ThreadSafe>> Pending;
	FSourceControlStateChanged OnStateChanged;
	// asynchronous operations: their completion is reported on the next Tick, as Unreal expects
	// (reported inside Execute, the status bar stayed on "Contacting server")
	TArray<TTuple<FSourceControlOperationRef, ECommandResult::Type, FSourceControlOperationComplete>> Done;
};
