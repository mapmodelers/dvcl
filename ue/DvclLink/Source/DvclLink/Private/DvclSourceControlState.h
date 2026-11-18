// State of one file for Unreal's revision control, as dvcl sees it (offline, from .dvcl\pending.tsv)
#pragma once

#include "CoreMinimal.h"
#include "ISourceControlState.h"
#include "ISourceControlRevision.h"

class FDvclSourceControlState : public ISourceControlState
{
public:
	// Kind: 'M' modified, 'A' added, 'D' deleted, 'R' renamed, '!' conflict, 0 = unchanged
	FDvclSourceControlState(const FString& InFilename, TCHAR InKind, const FString& InChangelist)
		: Filename(InFilename), Kind(InKind), Changelist(InChangelist), TimeStamp(FDateTime::Now())
	{
	}

	virtual int32 GetHistorySize() const override { return 0; }
	virtual TSharedPtr<ISourceControlRevision, ESPMode::ThreadSafe> GetHistoryItem(int32 HistoryIndex) const override { return nullptr; }
	virtual TSharedPtr<ISourceControlRevision, ESPMode::ThreadSafe> FindHistoryRevision(int32 RevisionNumber) const override { return nullptr; }
	virtual TSharedPtr<ISourceControlRevision, ESPMode::ThreadSafe> FindHistoryRevision(const FString& InRevision) const override { return nullptr; }
	virtual TSharedPtr<ISourceControlRevision, ESPMode::ThreadSafe> GetCurrentRevision() const override { return nullptr; }
#if SOURCE_CONTROL_WITH_SLATE
	virtual FSlateIcon GetIcon() const override;
#endif
	virtual FText GetDisplayName() const override;
	virtual FText GetDisplayTooltip() const override;
	virtual const FString& GetFilename() const override { return Filename; }
	virtual const FDateTime& GetTimeStamp() const override { return TimeStamp; }
	// check in / revert run dvcl's command line (submit-files / revert-files)
	// Diversion has no locks: every file is always editable, so it counts as checked out (no Check Out prompt in Unreal)
	virtual bool CanCheckIn() const override { return Kind != 0 && Kind != TEXT('!'); }
	virtual bool CanCheckout() const override { return false; }
	virtual bool IsCheckedOut() const override { return true; }
	virtual bool IsCheckedOutOther(FString* Who = nullptr) const override { return false; }
	virtual bool IsCheckedOutInOtherBranch(const FString& CurrentBranch = FString()) const override { return false; }
	virtual bool IsModifiedInOtherBranch(const FString& CurrentBranch = FString()) const override { return false; }
	virtual bool IsCheckedOutOrModifiedInOtherBranch(const FString& CurrentBranch = FString()) const override { return false; }
	virtual TArray<FString> GetCheckedOutBranches() const override { return TArray<FString>(); }
	virtual FString GetOtherUserBranchCheckedOuts() const override { return FString(); }
	virtual bool GetOtherBranchHeadModification(FString& HeadBranchOut, FString& ActionOut, int32& HeadChangeListOut) const override { return false; }
	virtual bool IsCurrent() const override { return true; }
	virtual bool IsSourceControlled() const override { return true; }
	virtual bool IsAdded() const override { return Kind == TEXT('A'); }
	virtual bool IsDeleted() const override { return Kind == TEXT('D'); }
	virtual bool IsIgnored() const override { return false; }
	virtual bool CanEdit() const override { return true; }
	virtual bool CanDelete() const override { return true; }
	virtual bool IsUnknown() const override { return false; }
	virtual bool IsModified() const override { return Kind != 0; }
	virtual bool CanAdd() const override { return false; }
	virtual bool IsConflicted() const override { return Kind == TEXT('!'); }
	// a new file has nothing to go back to (dvcl skips it): delete it instead
	virtual bool CanRevert() const override { return Kind != 0 && Kind != TEXT('A'); }
	// the blue line in Content Browser tooltips: only for files with a pending change (all files count as checked out)
	virtual TOptional<FText> GetStatusText() const override
	{
		TOptional<FText> Text = GetWarningText();
		if (!Text.IsSet() && Kind != 0)
		{
			Text.Emplace(GetDisplayTooltip());
		}
		return Text;
	}

	FString Filename;
	TCHAR Kind;
	FString Changelist;
	FDateTime TimeStamp;
};
