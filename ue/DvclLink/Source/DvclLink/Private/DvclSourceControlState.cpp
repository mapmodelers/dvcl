#include "DvclSourceControlState.h"

#include "RevisionControlStyle/RevisionControlStyle.h"
#include "Textures/SlateIcon.h"

#define LOCTEXT_NAMESPACE "DvclSourceControl"

#if SOURCE_CONTROL_WITH_SLATE
FSlateIcon FDvclSourceControlState::GetIcon() const
{
	const FName Style = FRevisionControlStyleManager::GetStyleSetName();
	switch (Kind)
	{
	case TEXT('M'):
	case TEXT('R'): return FSlateIcon(Style, "RevisionControl.CheckedOut");
	case TEXT('A'): return FSlateIcon(Style, "RevisionControl.OpenForAdd");
	case TEXT('D'): return FSlateIcon(Style, "RevisionControl.MarkedForDelete");
	case TEXT('!'): return FSlateIcon(Style, "RevisionControl.Conflicted");
	default: return FSlateIcon();
	}
}
#endif

FText FDvclSourceControlState::GetDisplayName() const
{
	switch (Kind)
	{
	case TEXT('M'): return LOCTEXT("Modified", "Modified");
	case TEXT('R'): return LOCTEXT("Renamed", "Renamed");
	case TEXT('A'): return LOCTEXT("Added", "Added");
	case TEXT('D'): return LOCTEXT("Deleted", "Deleted");
	case TEXT('!'): return LOCTEXT("Conflicted", "Conflicted");
	default: return LOCTEXT("Unchanged", "Unchanged");
	}
}

FText FDvclSourceControlState::GetDisplayTooltip() const
{
	if (Kind == 0)
	{
		return LOCTEXT("UnchangedTip", "No local change (dvcl)");
	}
	return FText::Format(LOCTEXT("PendingTip", "{0} - dvcl changelist {1}"), GetDisplayName(), FText::FromString(Changelist));
}

#undef LOCTEXT_NAMESPACE
