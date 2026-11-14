// dvcl link: what Unreal's own revision control does around a file operation, callable from Python
// (dvcl runs it through Python remote execution):
//   release_files(files): let go of the files (closes their file handles), unless an asset is unsaved
//   reload_files(files):  reload those that are loaded, rescan all of them in the asset registry
// Files are full paths. Each returns one line per file: "<state> <file>".
#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "DvclLinkLibrary.generated.h"

UCLASS()
class DVCLLINK_API UDvclLinkLibrary : public UBlueprintFunctionLibrary
{
	GENERATED_BODY()

public:
	// States: released, notloaded, notcontent, unsaved. With any "unsaved", nothing is released
	// (the last line is "abort unsaved").
	UFUNCTION(BlueprintCallable, Category = "dvcl")
	static FString ReleaseFiles(const TArray<FString>& Files);

	// States: reloaded, scanned, notcontent, error <message> (last line).
	UFUNCTION(BlueprintCallable, Category = "dvcl")
	static FString ReloadFiles(const TArray<FString>& Files);

	// "dvcl link <n>"
	UFUNCTION(BlueprintCallable, Category = "dvcl")
	static FString Version();
};
