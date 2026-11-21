// dvcl changelists in Unreal's revision control: one per dvcl changelist (#number, name, description)
// plus the default one. Read from the workspace's .dvcl\changelists.json; files from .dvcl\pending.tsv.
#pragma once

#include "CoreMinimal.h"
#include "ISourceControlChangelist.h"
#include "ISourceControlChangelistState.h"
#include "ISourceControlState.h"

class FDvclChangelist : public ISourceControlChangelist
{
public:
	// Id: the dvcl changelist number, 0 = default
	explicit FDvclChangelist(int32 InId)
		: Id(InId)
	{
	}

	virtual bool CanDelete() const override { return Id != 0; }
	virtual bool IsDefault() const override { return Id == 0; }
	virtual FString GetIdentifier() const override { return Id == 0 ? FString(TEXT("default")) : FString::FromInt(Id); }

	int32 Id;
};

class FDvclChangelistState : public ISourceControlChangelistState
{
public:
	FDvclChangelistState(int32 InId, const FString& InName, const FString& InDescription)
		: Id(InId), Name(InName), Description(InDescription), TimeStamp(FDateTime::Now())
	{
	}

	virtual FName GetIconName() const override { return FName("SourceControl.Changelist"); }
	virtual FName GetSmallIconName() const override { return GetIconName(); }
	virtual FText GetDisplayText() const override
	{
		return Id == 0 ? NSLOCTEXT("DvclSourceControl", "DefaultCl", "default") : FText::FromString(FString::Printf(TEXT("#%d %s"), Id, *Name));
	}
	virtual FText GetDescriptionText() const override { return FText::FromString(Description); }
	// the default changelist has no description of its own (as in dvcl)
	virtual bool SupportsPersistentDescription() const override { return Id != 0; }
	virtual FText GetDisplayTooltip() const override
	{
		return FText::Format(NSLOCTEXT("DvclSourceControl", "ClTip", "dvcl changelist {0}: {1} file(s)"), GetDisplayText(), FText::AsNumber(Files.Num()));
	}
	virtual const FDateTime& GetTimeStamp() const override { return TimeStamp; }
	virtual const TArray<FSourceControlStateRef> GetFilesStates() const override { return Files; }
	virtual int32 GetFilesStatesNum() const override { return Files.Num(); }
	virtual const TArray<FSourceControlStateRef> GetShelvedFilesStates() const override { return TArray<FSourceControlStateRef>(); }
	virtual int32 GetShelvedFilesStatesNum() const override { return 0; }
	virtual FSourceControlChangelistRef GetChangelist() const override { return MakeShared<FDvclChangelist, ESPMode::ThreadSafe>(Id); }

	int32 Id;
	FString Name;
	FString Description;
	FDateTime TimeStamp;
	TArray<FSourceControlStateRef> Files;
};
