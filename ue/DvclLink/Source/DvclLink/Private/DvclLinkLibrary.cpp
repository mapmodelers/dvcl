#include "DvclLinkLibrary.h"

#include "AssetRegistry/IAssetRegistry.h"
#include "Engine/World.h"
#include "GameFramework/Actor.h"
#include "LevelInstance/LevelInstanceInterface.h"
#include "Misc/PackageName.h"
#include "Misc/PackagePath.h"
#include "Misc/Paths.h"
#include "PackageTools.h"
#include "UObject/Package.h"
#include "UObject/UObjectGlobals.h"
#include "UObject/UObjectIterator.h"

namespace
{
	FString NormalFull(const FString& File)
	{
		FString Full = FPaths::ConvertRelativePathToFull(File);
		FPaths::NormalizeFilename(Full);
		return Full;
	}

	// Full file path -> long package name ("/Game/..."), empty if not content
	FString ToPackageName(const FString& File)
	{
		FString Name;
		if (!FPackageName::TryConvertFilenameToLongPackageName(NormalFull(File), Name))
		{
			return FString();
		}
		return Name;
	}

	// Every loaded package read from this file: the asset itself, and copies loaded under another
	// name. A level used as a level instance is loaded as "/Temp<package>_LevelInstance_<id>_<n>".
	TArray<UPackage*> PackagesFromFile(const FString& File, const FString& Name)
	{
		TArray<UPackage*> Result;
		const FString Full = NormalFull(File);
		const FString InstancePrefix = TEXT("/Temp") + Name + TEXT("_LevelInstance_");
		for (TObjectIterator<UPackage> It; It; ++It)
		{
			UPackage* Package = *It;
			if (!IsValid(Package))
			{
				continue;
			}
			const FString PackageName = Package->GetName();
			bool bMatch = PackageName == Name || PackageName.StartsWith(InstancePrefix);
			if (!bMatch)
			{
				const FPackagePath& Loaded = Package->GetLoadedPath();
				if (!Loaded.IsEmpty())
				{
					bMatch = Loaded.GetPackageName() == Name;
					if (!bMatch)
					{
						FString LoadedFile = Loaded.GetLocalFullPath();
						FPaths::NormalizeFilename(LoadedFile);
						bMatch = !LoadedFile.IsEmpty() && LoadedFile.Equals(Full, ESearchCase::IgnoreCase);
					}
				}
			}
			if (bMatch)
			{
				Result.Add(Package);
			}
		}
		return Result;
	}

	// Level instances placed from this level (in any loaded world, nested ones too)
	TArray<ILevelInstanceInterface*> LevelInstancesOf(const FString& Name)
	{
		TArray<ILevelInstanceInterface*> Result;
		for (TObjectIterator<AActor> It; It; ++It)
		{
			AActor* Actor = *It;
			if (!IsValid(Actor) || Actor->HasAnyFlags(RF_ClassDefaultObject | RF_ArchetypeObject))
			{
				continue;
			}
			if (ILevelInstanceInterface* Instance = Cast<ILevelInstanceInterface>(Actor))
			{
				if (Instance->GetWorldAsset().GetLongPackageName() == Name)
				{
					Result.Add(Instance);
				}
			}
		}
		return Result;
	}
}

FString UDvclLinkLibrary::ReleaseFiles(const TArray<FString>& Files)
{
	TArray<FString> Lines;
	TArray<UPackage*> ToReset;
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
		const TArray<UPackage*> Packages = PackagesFromFile(File, Name);
		if (Packages.Num() == 0)
		{
			Lines.Add(TEXT("notloaded ") + File);
			continue;
		}
		bool bDirty = false;
		for (UPackage* Package : Packages)
		{
			bDirty |= Package->IsDirty();
		}
		if (bDirty)
		{
			Lines.Add(TEXT("unsaved ") + File);
			bUnsaved = true;
			continue;
		}
		ToReset.Append(Packages);
		Lines.Add(FString::Printf(TEXT("released %s"), *File));
	}

	if (bUnsaved)
	{
		// your unsaved work in Unreal comes first: nothing is released
		Lines.Add(TEXT("abort unsaved"));
		return FString::Join(Lines, TEXT("\n"));
	}

	// what Unreal's revision control does before a sync / revert: the loaders let go of the files
	for (UPackage* Package : ToReset)
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
	TArray<ILevelInstanceInterface*> Instances;

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
			Existing.Add(NormalFull(File));
		}
		UPackage* Package = FindPackage(nullptr, *Name);
		const TArray<ILevelInstanceInterface*> FromLevel = LevelInstancesOf(Name);
		if (FromLevel.Num() > 0 && bExists)
		{
			// a level used as level instances: those instances load it again
			Instances.Append(FromLevel);
			Lines.Add(FString::Printf(TEXT("instances %d %s"), FromLevel.Num(), *File));
		}
		// a level used only as level instances is reloaded through them (below)
		if (Package && bExists && (FromLevel.Num() == 0 || !Package->ContainsMap()))
		{
			Loaded.Add(Package);
			Lines.Add(TEXT("reloaded ") + File);
		}
		else if (FromLevel.Num() == 0)
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

#if WITH_EDITOR
	for (ILevelInstanceInterface* Instance : Instances)
	{
		Instance->UpdateLevelInstanceFromWorldAsset();
	}
#endif
	return FString::Join(Lines, TEXT("\n"));
}

FString UDvclLinkLibrary::Version()
{
	return TEXT("dvcl link 3");
}
