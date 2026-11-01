"""Generate PoolWidget.xcodeproj/project.pbxproj (Xcode 16+ synchronized folders)."""
import hashlib
import os
import sys

root = sys.argv[1]
TEAM = "4JAWF8AN8G"


def oid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


ids = {k: oid(k) for k in """project mainGroup productsGroup
grpShared grpApp grpExt grpTests excApp excExt
tApp tExt tTests prodApp prodExt prodTests
srcApp resApp fwApp embedApp srcExt resExt fwExt srcTests resTests fwTests
embedExtFile depExt proxyExt
cfgListProject cfgProjDebug cfgProjRelease
cfgListApp cfgAppDebug cfgAppRelease cfgListExt cfgExtDebug cfgExtRelease
cfgListTests cfgTestsDebug cfgTestsRelease""".split()}
I = ids

common_proj = f"""
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = {TEAM};
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 5.0;
				MARKETING_VERSION = 1.0;
				CURRENT_PROJECT_VERSION = 1;"""


def bs(extra, debug):
    d = """
				DEBUG_INFORMATION_FORMAT = dwarf;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;""" if debug else """
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				SWIFT_COMPILATION_MODE = wholemodule;"""
    return extra + d


app_bs = """
				PRODUCT_BUNDLE_IDENTIFIER = com.askasen.PoolMonitor;
				PRODUCT_NAME = "$(TARGET_NAME)";
				INFOPLIST_FILE = PoolMonitor/Info.plist;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "Pool Monitor";
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities";
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				CODE_SIGN_ENTITLEMENTS = PoolMonitor/PoolMonitor.entitlements;
				ENABLE_HARDENED_RUNTIME = YES;
				COMBINE_HIDPI_IMAGES = YES;
				LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/../Frameworks");
				SWIFT_EMIT_LOC_STRINGS = NO;"""
ext_bs = """
				PRODUCT_BUNDLE_IDENTIFIER = com.askasen.PoolMonitor.Widget;
				PRODUCT_NAME = "$(TARGET_NAME)";
				INFOPLIST_FILE = PoolWidgetExtension/Info.plist;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "Pool Status";
				CODE_SIGN_ENTITLEMENTS = PoolWidgetExtension/PoolWidgetExtension.entitlements;
				ENABLE_HARDENED_RUNTIME = YES;
				SKIP_INSTALL = YES;
				LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks");
				SWIFT_EMIT_LOC_STRINGS = NO;"""
tests_bs = """
				PRODUCT_BUNDLE_IDENTIFIER = com.askasen.PoolMonitorTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				GENERATE_INFOPLIST_FILE = YES;
				SWIFT_EMIT_LOC_STRINGS = NO;"""


def cfg(id_, name, settings):
    return f"""		{id_} /* {name} */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{settings}
			}};
			name = {name};
		}};
"""


def target(tid, name, ptype, prod, cfglist, phases, groups, deps=""):
    return f"""		{tid} /* {name} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {cfglist};
			buildPhases = ({", ".join(phases)});
			buildRules = ();
			dependencies = ({deps});
			fileSystemSynchronizedGroups = ({", ".join(groups)});
			name = {name};
			productName = {name};
			productReference = {prod};
			productType = "{ptype}";
		}};
"""


def phase(pid, isa, extra=""):
    return f"""		{pid} = {{
			isa = {isa};
			buildActionMask = 2147483647;
			files = ({extra});
			runOnlyForDeploymentPostprocessing = 0;
		}};
"""


out = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{}};
	objectVersion = 77;
	objects = {{
		{I['embedExtFile']} = {{isa = PBXBuildFile; fileRef = {I['prodExt']}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
		{I['proxyExt']} = {{isa = PBXContainerItemProxy; containerPortal = {I['project']}; proxyType = 1; remoteGlobalIDString = {I['tExt']}; remoteInfo = PoolWidgetExtension; }};
		{I['depExt']} = {{isa = PBXTargetDependency; target = {I['tExt']}; targetProxy = {I['proxyExt']}; }};
		{I['embedApp']} = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = ({I['embedExtFile']}, );
			name = "Embed Foundation Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['prodApp']} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PoolMonitor.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['prodExt']} = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = PoolWidgetExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['prodTests']} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = PoolMonitorTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['excApp']} = {{isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Info.plist, PoolMonitor.entitlements, ); target = {I['tApp']}; }};
		{I['excExt']} = {{isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Info.plist, PoolWidgetExtension.entitlements, ); target = {I['tExt']}; }};
		{I['grpShared']} = {{isa = PBXFileSystemSynchronizedRootGroup; path = Shared; sourceTree = "<group>"; }};
		{I['grpApp']} = {{isa = PBXFileSystemSynchronizedRootGroup; exceptions = ({I['excApp']}, ); path = PoolMonitor; sourceTree = "<group>"; }};
		{I['grpExt']} = {{isa = PBXFileSystemSynchronizedRootGroup; exceptions = ({I['excExt']}, ); path = PoolWidgetExtension; sourceTree = "<group>"; }};
		{I['grpTests']} = {{isa = PBXFileSystemSynchronizedRootGroup; path = PoolMonitorTests; sourceTree = "<group>"; }};
		{I['mainGroup']} = {{isa = PBXGroup; children = ({I['grpShared']}, {I['grpApp']}, {I['grpExt']}, {I['grpTests']}, {I['productsGroup']}, ); sourceTree = "<group>"; }};
		{I['productsGroup']} = {{isa = PBXGroup; children = ({I['prodApp']}, {I['prodExt']}, {I['prodTests']}, ); name = Products; sourceTree = "<group>"; }};
"""
for p, isa in [("srcApp", "PBXSourcesBuildPhase"), ("resApp", "PBXResourcesBuildPhase"), ("fwApp", "PBXFrameworksBuildPhase"),
               ("srcExt", "PBXSourcesBuildPhase"), ("resExt", "PBXResourcesBuildPhase"), ("fwExt", "PBXFrameworksBuildPhase"),
               ("srcTests", "PBXSourcesBuildPhase"), ("resTests", "PBXResourcesBuildPhase"), ("fwTests", "PBXFrameworksBuildPhase")]:
    out += phase(I[p], isa)
out += target(I['tApp'], "PoolMonitor", "com.apple.product-type.application", I['prodApp'], I['cfgListApp'],
              [I['srcApp'], I['fwApp'], I['resApp'], I['embedApp']], [I['grpShared'], I['grpApp']], I['depExt'] + ", ")
out += target(I['tExt'], "PoolWidgetExtension", "com.apple.product-type.app-extension", I['prodExt'], I['cfgListExt'],
              [I['srcExt'], I['fwExt'], I['resExt']], [I['grpShared'], I['grpExt']])
out += target(I['tTests'], "PoolMonitorTests", "com.apple.product-type.bundle.unit-test", I['prodTests'], I['cfgListTests'],
              [I['srcTests'], I['fwTests'], I['resTests']], [I['grpShared'], I['grpTests']])
out += f"""		{I['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
			}};
			buildConfigurationList = {I['cfgListProject']};
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (en, Base, );
			mainGroup = {I['mainGroup']};
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = {I['productsGroup']};
			projectDirPath = "";
			projectRoot = "";
			targets = ({I['tApp']}, {I['tExt']}, {I['tTests']}, );
		}};
"""
out += cfg(I['cfgProjDebug'], "Debug", bs(common_proj, True)) + cfg(I['cfgProjRelease'], "Release", bs(common_proj, False))
for t, s in [("App", app_bs), ("Ext", ext_bs), ("Tests", tests_bs)]:
    out += cfg(I[f'cfg{t}Debug'], "Debug", s) + cfg(I[f'cfg{t}Release'], "Release", s)
for lst, dbg, rel in [("cfgListProject", "cfgProjDebug", "cfgProjRelease"), ("cfgListApp", "cfgAppDebug", "cfgAppRelease"),
                      ("cfgListExt", "cfgExtDebug", "cfgExtRelease"), ("cfgListTests", "cfgTestsDebug", "cfgTestsRelease")]:
    out += f"""		{I[lst]} = {{
			isa = XCConfigurationList;
			buildConfigurations = ({I[dbg]}, {I[rel]}, );
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
"""
out += f"""	}};
	rootObject = {I['project']} /* Project object */;
}}
"""
d = os.path.join(root, "PoolWidget.xcodeproj")
os.makedirs(d, exist_ok=True)
open(os.path.join(d, "project.pbxproj"), "w").write(out)
print("wrote", d)
