#include "DvclSourceControlProvider.h"
#include "Features/IModularFeatures.h"
#include "Modules/ModuleManager.h"

// dvcl link: the Python calls dvcl uses (DvclLinkLibrary) and "dvcl" in Unreal's revision control
class FDvclLinkModule : public IModuleInterface
{
public:
	virtual void StartupModule() override
	{
		IModularFeatures::Get().RegisterModularFeature("SourceControl", &Provider);
	}
	virtual void ShutdownModule() override
	{
		Provider.Close();
		IModularFeatures::Get().UnregisterModularFeature("SourceControl", &Provider);
	}

private:
	FDvclSourceControlProvider Provider;
};

IMPLEMENT_MODULE(FDvclLinkModule, DvclLink)
