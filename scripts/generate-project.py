#!/usr/bin/env python3
"""Generate a dependency-free Xcode project with native iOS and macOS targets."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
objects = []
def obj(i, value):
    objects.append(f'{i:024X} = {{ {value} }};')
def ref(i): return f'{i:024X}'
obj(1, f'isa = PBXProject; buildConfigurationList = {ref(3)}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {ref(2)}; productRefGroup = {ref(5)}; projectDirPath = ""; projectRoot = ""; targets = ({ref(10)}, {ref(20)});')
obj(2, f'isa = PBXGroup; children = ({ref(4)}, {ref(100)}, {ref(300)}, {ref(400)}, {ref(500)}, {ref(600)}, {ref(700)}, {ref(800)}, {ref(900)}, {ref(1000)}, {ref(1100)}, {ref(1200)}, {ref(1300)}, {ref(1400)}, {ref(200)}, {ref(5)}); sourceTree = "<group>";')
obj(4, 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App/VibeRadio.swift; sourceTree = "<group>";')
obj(100, 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App/StudioViews.swift; sourceTree = "<group>";')
for file_id, path in [(300,'AIClient.swift'),(400,'DJChatModel.swift'),(500,'AISettingsView.swift'),(600,'MusicCatalog.swift'),(700,'MusicLibraryModel.swift'),(800,'MusicPoolView.swift'),(900,'DJVoice.swift'),(1000,'Companion.swift'),(1100,'ContextServices.swift'),(1200,'StudioBrain.swift'),(1300,'StudioFeatureViews.swift'),(1400,'UPnP.swift')]:
    obj(file_id, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App/{path}; sourceTree = "<group>";')
obj(200, 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = App/Assets.xcassets; sourceTree = "<group>";')
obj(5, f'isa = PBXGroup; name = Products; children = ({ref(11)}, {ref(21)}); sourceTree = "<group>";')
obj(3, f'isa = XCConfigurationList; buildConfigurations = ({ref(6)}, {ref(7)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for i, name in [(6, 'Debug'), (7, 'Release')]:
    obj(i, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{"DEBUG" if name == "Debug" else ""}"; SWIFT_OPTIMIZATION_LEVEL = "{"-Onone" if name == "Debug" else "-O"}"; }};')
for base, platform in [(10, 'iOS'), (20, 'macOS')]:
    name = 'VibeRadio-' + platform
    obj(base, f'isa = PBXNativeTarget; buildConfigurationList = {ref(base+3)}; buildPhases = ({ref(base+2)}, {ref(base+7)}); buildRules = (); dependencies = (); name = "{name}"; productName = VibeRadio; productReference = {ref(base+1)}; productType = "com.apple.product-type.application";')
    obj(base+1, f'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{name}.app"; sourceTree = BUILT_PRODUCTS_DIR;')
    obj(base+2, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ref(base+4)}, {ref(base+100)}, {ref(base+300)}, {ref(base+400)}, {ref(base+500)}, {ref(base+600)}, {ref(base+700)}, {ref(base+800)}, {ref(base+900)}, {ref(base+1000)}, {ref(base+1100)}, {ref(base+1200)}, {ref(base+1300)}, {ref(base+1400)}); runOnlyForDeploymentPostprocessing = 0;')
    obj(base+3, f'isa = XCConfigurationList; buildConfigurations = ({ref(base+5)}, {ref(base+6)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    obj(base+4, f'isa = PBXBuildFile; fileRef = {ref(4)};')
    obj(base+100, f'isa = PBXBuildFile; fileRef = {ref(100)};')
    for file_id in [300,400,500,600,700,800,900,1000,1100,1200,1300,1400]:
        obj(base+file_id, f'isa = PBXBuildFile; fileRef = {ref(file_id)};')
    obj(base+200, f'isa = PBXBuildFile; fileRef = {ref(200)};')
    obj(base+7, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ref(base+200)}); runOnlyForDeploymentPostprocessing = 0;')
    for i, config in [(base+5, 'Debug'), (base+6, 'Release')]:
        settings = f'''PRODUCT_NAME = "{name}";
        PRODUCT_BUNDLE_IDENTIFIER = "dev.viberadio.prototype.{platform.lower()}";
        GENERATE_INFOPLIST_FILE = YES;
        INFOPLIST_KEY_CFBundleDisplayName = VibeRadio;
        ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        INFOPLIST_KEY_NSLocalNetworkUsageDescription = "连接你的本地网易云音乐桥接服务";
        INFOPLIST_KEY_NSMicrophoneUsageDescription = "语音告诉 DJ 你想听什么";
        INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "把你说的话转成文字发给 DJ";
        INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = "读取今天的日程，让 DJ 按你的一天安排音乐";
        MARKETING_VERSION = 0.1.0; CURRENT_PROJECT_VERSION = 1;
        CODE_SIGN_STYLE = Automatic;
        ENABLE_APP_SANDBOX = NO;
        SWIFT_EMIT_LOC_STRINGS = YES;'''
        if platform == 'iOS':
            settings += '''SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
            IPHONEOS_DEPLOYMENT_TARGET = 17.0; TARGETED_DEVICE_FAMILY = "1,2";
            INFOPLIST_KEY_UILaunchScreen_Generation = YES;
            INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
            INFOPLIST_FILE = App/Info-iOS.plist;'''
        else:
            settings += 'SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0;'
        obj(i, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {settings} }};')
p = root / 'VibeRadio.xcodeproj'
p.mkdir(exist_ok=True)
(p / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ref(1)}; }}\n')
