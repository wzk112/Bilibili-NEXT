#!/usr/bin/env python3
"""Generate the checked-in Xcode project without third-party build dependencies."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'Apps/iOS'
SHARED = '''BrowsePreferences PlaybackSequence InterfaceMotion API AppCoinAuthorization LoginRestoration Community VideoActions OfficialChallenge CommentPage CommentText CommentVideoLink VideoExtras VideoPreview SearchFeatures Regions AccountHistory MessageShare NativeSpace DynamicPublishing Messaging ImageUpload WatchHistorySync AppDateFormat ThumbnailCache TaskDeadline Player PlaybackProgressDeadline CDNSelection ParallelVideoStream PlaybackDiskCache VideoSignalling MP4Compatibility DanmakuModels Downloads DownloadPiece DownloadPublication NotificationModels EmojiPicker ConversationTimeline DanmakuLayout DanmakuCloudRules DanmakuTextBitmap DanmakuSettings BiliImageURL DynamicAttachment BAS SVGPath SpecialDanmaku'''.split()

def uid(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(value)

sources = [(f'../../Sources/BiliGlass/{name}.swift', name + '.swift') for name in SHARED]
sources += [(str(p.relative_to(APP)), p.name) for p in sorted((APP / 'Sources').glob('*.swift'))]
resources = [('Resources/Assets.xcassets', 'Assets.xcassets', 'folder.assetcatalog'),
             ('Resources/LICENSE.txt', 'LICENSE.txt', 'text'),
             ('Resources/BiliKit-LICENSE.txt', 'BiliKit-LICENSE.txt', 'text'),
             ('Resources/THIRD_PARTY.md', 'THIRD_PARTY.md', 'text'),
             ('../../CHANGELOG.md', 'CHANGELOG.md', 'text')]
objects = []
def add(key, body):
    objects.append(f'\t\t{uid(key)} = {{ {body} }};')

for path, name in sources:
    add('ref:'+path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = SOURCE_ROOT;')
    add('build:'+path, f'isa = PBXBuildFile; fileRef = {uid("ref:"+path)};')
for path, name, kind in resources:
    add('ref:'+path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path)}; sourceTree = SOURCE_ROOT;')
    add('build:'+path, f'isa = PBXBuildFile; fileRef = {uid("ref:"+path)};')
libs = ['BiliModels', 'BiliNetworking', 'BiliPlayback']
for lib in libs:
    add('pkg:'+lib, f'isa = XCSwiftPackageProductDependency; package = {uid("package")}; productName = {lib};')
    add('link:'+lib, f'isa = PBXBuildFile; productRef = {uid("pkg:"+lib)};')
add('package', 'isa = XCLocalSwiftPackageReference; relativePath = ../../Vendor/BiliKitCore;')
add('ui-ref', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITests/MobileSmokeTests.swift; sourceTree = SOURCE_ROOT;')
add('ui-build', f'isa = PBXBuildFile; fileRef = {uid("ui-ref")};')
add('ui-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = BilibiliNEXTUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
add('ui-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("ui-build")},); runOnlyForDeploymentPostprocessing = 0;')
add('ui-proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = BilibiliNEXT;')
add('ui-dependency', f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {uid("ui-proxy")};')
add('ui-target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("ui-configs")}; buildPhases = ({uid("ui-sources")},); buildRules = (); dependencies = ({uid("ui-dependency")},); name = BilibiliNEXTUITests; productName = BilibiliNEXTUITests; productReference = {uid("ui-product")}; productType = "com.apple.product-type.bundle.ui-testing";')
for config in ['Debug', 'Release']:
    add('ui-'+config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.wzk112.BilibiliNEXT.iOS.UITests; PRODUCT_NAME = "$(TARGET_NAME)"; TEST_TARGET_NAME = BilibiliNEXT; TARGETED_DEVICE_FAMILY = "1,2"; SWIFT_VERSION = 5.0; ENABLE_TESTING_SEARCH_PATHS = YES; }};')
add('ui-configs', f'isa = XCConfigurationList; buildConfigurations = ({uid("ui-Debug")},{uid("ui-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Bilibili NEXT.app"; sourceTree = BUILT_PRODUCTS_DIR;')
add('products', f'isa = PBXGroup; children = ({uid("product")},{uid("ui-product")},); name = Products; sourceTree = "<group>";')
refs = [uid("ui-ref")] + [uid('ref:'+p) for p, _ in sources] + [uid('ref:'+p) for p, _, _ in resources]
add('group', f'isa = PBXGroup; children = ({",".join(refs)},{uid("products")},); sourceTree = "<group>";')
add('sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(uid('build:'+p) for p,_ in sources)+',); runOnlyForDeploymentPostprocessing = 0;')
add('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(uid('build:'+p) for p,_,_ in resources)+',); runOnlyForDeploymentPostprocessing = 0;')
add('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ('+','.join(uid('link:'+l) for l in libs)+',); runOnlyForDeploymentPostprocessing = 0;')
add('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")},); buildRules = (); dependencies = (); name = BilibiliNEXT; packageProductDependencies = ({",".join(uid("pkg:"+l) for l in libs)},); productName = BilibiliNEXT; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
project_settings = {'CLANG_ENABLE_MODULES':'YES', 'SWIFT_VERSION':'5.0', 'IPHONEOS_DEPLOYMENT_TARGET':'26.0', 'SDKROOT':'iphoneos', 'SWIFT_STRICT_CONCURRENCY':'minimal'}
target_settings = {'PRODUCT_NAME':'Bilibili NEXT', 'PRODUCT_BUNDLE_IDENTIFIER':'com.wzk112.BilibiliNEXT.iOS', 'INFOPLIST_FILE':'Info.plist', 'GENERATE_INFOPLIST_FILE':'NO', 'CODE_SIGN_STYLE':'Automatic', 'TARGETED_DEVICE_FAMILY':'1,2', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'ENABLE_PREVIEWS':'YES', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks', 'SUPPORTS_MACCATALYST':'NO'}
for config in ['Debug','Release']:
    for scope, values in [('project',project_settings),('target',target_settings)]:
        values = dict(values)
        if config == 'Debug':
            values.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG $(inherited)', 'DEBUG_INFORMATION_FORMAT':'dwarf'})
        else:
            values.update({'SWIFT_OPTIMIZATION_LEVEL':'-O', 'DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym'})
        body = ' '.join(f'{k} = {quote(v)};' for k,v in values.items())
        add(scope+config, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};')
for scope in ['project','target']:
    add(scope+'-configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(scope+"Debug")},{uid(scope+"Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2710; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,"zh-Hans",); mainGroup = {uid("group")}; packageReferences = ({uid("package")},); productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},{uid("ui-target")},);')
project = APP / 'BilibiliNEXT.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n')
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="Bilibili NEXT.app" BlueprintName="BilibiliNEXT" ReferencedContainer="container:BilibiliNEXT.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('ui-target')}" BuildableName="BilibiliNEXTUITests.xctest" BlueprintName="BilibiliNEXTUITests" ReferencedContainer="container:BilibiliNEXT.xcodeproj"/></TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="Bilibili NEXT.app" BlueprintName="BilibiliNEXT" ReferencedContainer="container:BilibiliNEXT.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="Bilibili NEXT.app" BlueprintName="BilibiliNEXT" ReferencedContainer="container:BilibiliNEXT.xcodeproj"/></BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'BilibiliNEXT.xcscheme').write_text(scheme)
print(project)
