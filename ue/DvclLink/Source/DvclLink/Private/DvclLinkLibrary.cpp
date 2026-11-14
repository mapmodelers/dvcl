#include "DvclLinkLibrary.h"

#include "AssetRegistry/IAssetRegistry.h"
#include "Misc/PackageName.h"
#include "Misc/Paths.h"
#include "PackageTools.h"
#include "UObject/Package.h"
#include "UObject/UObjectGlobals.h"

namespace
{
	// Full file path -> long package name ("/Game/..."), empty if not content
	FString ToPackageName(const FString& File)
	{
		FString Name;
		FString Full = FPaths::ConvertRelativePathToFull(File);
		FPaths::NormalizeFilename(Full);
		if (!FPackageName::TryConvertFilenameToLongPackageName(Full, Name))
		{
			return FString();
		}
		return Name;
	}
}

FString UDvclLinkLibrary::ReleaseFiles(const TArray<FString>& Files)
{
	TArray<FString> Lines;
	TArray<UPackage*> Loaded;
	bool bUnsaved = false;

	// finish any loading in flight before touching loaders
	FlushAsyncLoading();

	for (const FString& File : Files)
	{
		const FString Name = ToPackageName(File);
		if (Name.IsEmpty())
		{
			Lines.Add(TEXT("notcontent ") + File);
			continue;
		}
		UPackage* Package = FindPackage(nullptr, *Name);
		if (!Package)
		{
			Lines.Add(TEXT("notloaded ") + File);
			continue;
		}
		if (Package->IsDirty())
		{
			Lines.Add(TEXT("unsaved ") + File);
			bUnsaved = true;
			continue;
		}
		Loaded.Add(Package);
		Lines.Add(TEXT("released ") + File);
	}

	if (bUnsaved)
	{
		// your unsaved work in Unreal comes first: nothing is released
		Lines.Add(TEXT("abort unsaved"));
		return FString::Join(Lines, TEXT("\n"));
	}

	// what Unreal's revision control does before a sync / revert: the loaders let go of the files
	for (UPackage* Package : Loaded)
	{
		ResetLoaders(Package);
	}
	return FString::Join(Lines, TEXT("\n"));
}

FString UDvclLinkLibrary::ReloadFiles(const TArray<FString>& Files)
{
	TArray<FString> Lines;
	TArray<UPackage*> Loaded;
	TArray<FString> Existing;

	for (const FString& File : Files)
	{
		const FString Name = ToPackageName(File);
		if (Name.IsEmpty())
		{
			Lines.Add(TEXT("notcontent ") + File);
			continue;
		}
		const bool bExists = FPaths::FileExists(File);
		if (bExists)
		{
			Existing.Add(FPaths::ConvertRelativePathToFull(File));
		}
		UPackage* Package = FindPackage(nullptr, *Name);
		if (Package && bExists)
		{
			Loaded.Add(Package);
			Lines.Add(TEXT("reloaded ") + File);
		}
		else
		{
			Lines.Add(TEXT("scanned ") + File);
		}
	}

	// new / changed / removed files: the asset registry looks again
	if (Existing.Num() > 0)
	{
		IAssetRegistry::GetChecked().ScanFilesSynchronous(Existing, true);
	}

	// loaded assets: read again from disk, references kept (as after a revision-control sync)
	if (Loaded.Num() > 0)
	{
		FText Error;
		if (!UPackageTools::ReloadPackages(Loaded, Error, UPackageTools::EReloadPackagesInteractionMode::AssumePositive))
		{
			Lines.Add(TEXT("error ") + Error.ToString());
		}
	}
	return FString::Join(Lines, TEXT("\n"));
}

FString UDvclLinkLibrary::Version()
{
	return TEXT("dvcl link 1");
}
