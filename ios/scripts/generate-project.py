#!/usr/bin/env python3
"""Generate the dependency-free Xcode project deterministically; no XcodeGen needed."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}


class Ref(str):
    pass


def identifier(name):
    return Ref(hashlib.sha256(name.encode()).hexdigest()[:24].upper())


def add(key_name, isa, **values):
    key = identifier(key_name)
    objects[key] = dict(isa=isa, **values)
    return key


def encode(value, level=0):
    indent = "\t" * level
    if isinstance(value, Ref):
        return value
    if isinstance(value, dict):
        return "{\n" + "".join(f"{indent}\t{encode(k)} = {encode(v, level + 1)};\n" for k, v in value.items()) + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f"{indent}\t{encode(v, level + 1)},\n" for v in value) + indent + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


app_files = ["App/HealthApp.swift", "App/HealthAPI.swift", "App/NativeStore.swift", "App/WorkoutCoordinator.swift",
             "App/NativeComponents.swift", "App/NativeMuscleMap.swift", "App/NativeDashboardView.swift", "App/NativeTrainingView.swift",
             "App/NativeLibraryView.swift", "App/NativeSleepView.swift", "App/NativeDesignFixtures.swift", "App/NativeWorkoutView.swift", "App/NativeHistoryView.swift", "App/NativeSettingsView.swift",
             "Shared/WorkoutSnapshot.swift", "Shared/HealthRoute.swift", "Shared/NativeJSON.swift", "Shared/NativeCache.swift", "Shared/NativeTimeline.swift", "Shared/NativeTraining.swift", "Activity/WorkoutAttributes.swift", "Activity/WorkoutIntents.swift"]
widget_files = ["Activity/WorkoutLiveActivity.swift", "Activity/WorkoutAttributes.swift", "Activity/WorkoutIntents.swift",
                "Shared/WorkoutSnapshot.swift", "Shared/HealthRoute.swift"]
test_files = ["Tests/HealthUITests.swift"]
file_refs = {}
for path in dict.fromkeys(app_files + widget_files + test_files):
    file_refs[path] = add(path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path, sourceTree="<group>")
config = add("config", "PBXFileReference", lastKnownFileType="text.xcconfig", path="Config/Health.xcconfig", sourceTree="<group>")
asset = add("assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path="App/Assets.xcassets", sourceTree="<group>")
muscles = add("muscles", "PBXFileReference", lastKnownFileType="text.json", path="App/Resources/MusclePaths.json", sourceTree="<group>")
agpl = add("agpl", "PBXFileReference", lastKnownFileType="text", path="App/Resources/AGPL-3.0.txt", sourceTree="<group>")
notices = add("notices", "PBXFileReference", lastKnownFileType="text", path="App/Resources/THIRD_PARTY_NOTICES.txt", sourceTree="<group>")
chime = add("rest-chime", "PBXFileReference", lastKnownFileType="audio.wav", path="App/RestComplete.wav", sourceTree="<group>")
info = [add(p, "PBXFileReference", lastKnownFileType="text.plist.xml", path=p, sourceTree="<group>") for p in ("App/Info.plist", "Activity/Info.plist")]
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="Health.app", sourceTree="BUILT_PRODUCTS_DIR")
widget_product = add("widget-product", "PBXFileReference", explicitFileType="wrapper.app-extension", path="WorkoutWidget.appex", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="HealthUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", "PBXGroup", children=[app_product, widget_product, test_product], name="Products", sourceTree="<group>")
group = add("root-group", "PBXGroup", children=list(file_refs.values()) + [config, asset, chime, muscles, notices, agpl] + info + [products], sourceTree="<group>")
project_id = identifier("project")
app_id, widget_id = identifier("app-target"), identifier("widget-target")


def configs(name, settings, base=False):
    result = []
    for mode in ("Debug", "Release"):
        values = dict(settings)
        values.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O", DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym")
        if mode == "Debug":
            values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG"
            values["ENABLE_TESTABILITY"] = "YES"
            values["ONLY_ACTIVE_ARCH"] = "YES"
        options = dict(baseConfigurationReference=config) if base else {}
        result.append(add(name + mode, "XCBuildConfiguration", name=mode, buildSettings=values, **options))
    return add(name + "-configs", "XCConfigurationList", buildConfigurations=result, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


project_configs = configs("project", {
    "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "SWIFT_EMIT_LOC_STRINGS": "YES",
}, base=True)


def target(name, title, product_type, paths, product, settings, dependencies=None, extra_phases=None):
    build_files = [add(name + path, "PBXBuildFile", fileRef=file_refs[path]) for path in paths]
    sources = add(name + "-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=build_files, runOnlyForDeploymentPostprocessing=0)
    resources = []
    if name == "app":
        resources.append(add("asset-build", "PBXBuildFile", fileRef=asset))
        resources.append(add("chime-build", "PBXBuildFile", fileRef=chime))
        resources.append(add("muscles-build", "PBXBuildFile", fileRef=muscles))
        resources.append(add("notices-build", "PBXBuildFile", fileRef=notices))
        resources.append(add("agpl-build", "PBXBuildFile", fileRef=agpl))
    resource_phase = add(name + "-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)
    frameworks = add(name + "-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    return add(name + "-target", "PBXNativeTarget", name=title,
               buildConfigurationList=configs(name, settings), buildPhases=[sources, frameworks, resource_phase] + (extra_phases or []),
               buildRules=[], dependencies=dependencies or [], productName=title, productReference=product,
               productType="com.apple.product-type." + product_type)


widget = target("widget", "WorkoutWidget", "app-extension", widget_files, widget_product, {
    "PRODUCT_NAME": "WorkoutWidget", "PRODUCT_BUNDLE_IDENTIFIER": "$(APP_BUNDLE_IDENTIFIER).workout",
    "INFOPLIST_FILE": "Activity/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
    "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
})
proxy = add("widget-proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1, remoteGlobalIDString=widget, remoteInfo="WorkoutWidget")
dependency = add("widget-dependency", "PBXTargetDependency", target=widget, targetProxy=proxy)
embed_file = add("widget-embed-file", "PBXBuildFile", fileRef=widget_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed = add("embed-widget", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13, files=[embed_file], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0)
app = target("app", "Health", "application", app_files, app_product, {
    "PRODUCT_NAME": "Health", "PRODUCT_BUNDLE_IDENTIFIER": "$(APP_BUNDLE_IDENTIFIER)",
    "INFOPLIST_FILE": "App/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "SKIP_INSTALL": "NO",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
}, dependencies=[dependency], extra_phases=[embed])
test_proxy = add("test-app-proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1, remoteGlobalIDString=app, remoteInfo="Health")
test_dependency = add("test-app-dependency", "PBXTargetDependency", target=app, targetProxy=test_proxy)
ui_tests = target("ui-tests", "HealthUITests", "bundle.ui-testing", test_files, test_product, {
    "PRODUCT_NAME": "HealthUITests", "PRODUCT_BUNDLE_IDENTIFIER": "$(APP_BUNDLE_IDENTIFIER).uitests",
    "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "Health", "SKIP_INSTALL": "YES",
}, dependencies=[test_dependency])
add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600",
    "TargetAttributes": {app: {"CreatedOnToolsVersion": "16.0", "ProvisioningStyle": "Automatic"}, widget: {"CreatedOnToolsVersion": "16.0", "ProvisioningStyle": "Automatic"}, ui_tests: {"TestTargetID": app}}},
    buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base", "zh-Hans"],
    hasScannedForEncodings=0, mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, widget, ui_tests])
project = ROOT / "Health.xcodeproj"
project.mkdir(exist_ok=True)
body = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_id}
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(body) + "\n")
scheme = project / "xcshareddata/xcschemes/Health.xcscheme"
scheme.parent.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Health.app" BlueprintName="Health" ReferencedContainer="container:Health.xcodeproj"/>'
test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_tests}" BuildableName="HealthUITests.xctest" BlueprintName="HealthUITests" ReferencedContainer="container:Health.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{test_reference}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

common_info = dict(CFBundleDevelopmentRegion="$(DEVELOPMENT_LANGUAGE)", CFBundleExecutable="$(EXECUTABLE_NAME)",
                   CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleInfoDictionaryVersion="6.0",
                   CFBundleName="$(PRODUCT_NAME)", CFBundleShortVersionString="$(MARKETING_VERSION)", CFBundleVersion="$(CURRENT_PROJECT_VERSION)")
app_info = dict(common_info, PineCommit="$(PINE_COMMIT)", CFBundleName="Pine", CFBundleDisplayName="Pine", CFBundlePackageType="APPL", LSRequiresIPhoneOS=True,
                NSSupportsLiveActivities=True, UILaunchScreen={},
                UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": False, "UISceneConfigurations": {}},
                UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait"],
                CFBundleURLTypes=[{"CFBundleURLName": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleURLSchemes": ["healthfp"]}])
widget_info = dict(common_info, CFBundleDisplayName="Pine Workout", CFBundlePackageType="XPC!",
                   NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"})
for path, value in (("App/Info.plist", app_info), ("Activity/Info.plist", widget_info)):
    (ROOT / path).write_bytes(plistlib.dumps(value, sort_keys=False))
print("Generated Health.xcodeproj, shared scheme and Info.plists.")
