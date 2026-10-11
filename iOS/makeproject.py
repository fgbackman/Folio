#!/usr/bin/env python3
"""Writes FolioMobile.xcodeproj, the iPhone and iPad build of Folio.

Run from the top of the repository after adding or removing source files:  python3 iOS/makeproject.py
The Mac-only sources listed in MAC_ONLY are left out; everything else in App/, iOS/ and core/ goes in.
"""
import hashlib, os

MAC_ONLY = {"CoverMetal.swift", "CoverScene.swift", "CoverShaders.swift", "FolioApp.swift", "FloatingBook.swift",
            "PageTurner.swift", "Spotlight.swift", "Sync.swift"}
NOT_ENGINE = {"rdtool.c"}

def uid(name): return hashlib.md5(name.encode()).hexdigest()[:24].upper()

swift = [("App", f) for f in sorted(os.listdir("App")) if f.endswith(".swift") and f not in MAC_ONLY]
swift += [("iOS", f) for f in sorted(os.listdir("iOS")) if f.endswith(".swift")]
c = [("core", f) for f in sorted(os.listdir("core")) if f.endswith(".c") and f not in NOT_ENGINE]
headers = [("core", f) for f in sorted(os.listdir("core")) if f.endswith(".h")] + [("App", "Folio-Bridging-Header.h")]
sources = swift + c

def kind(f): return {"swift": "sourcecode.swift", "c": "sourcecode.c.c", "h": "sourcecode.c.h"}[f.rsplit(".", 1)[1]]

refs, builds, groups = [], [], {"App": [], "iOS": [], "core": []}
for folder, f in sources + headers:
    r = uid("ref/" + folder + "/" + f)
    refs.append(f'\t\t{r} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {kind(f)}; path = {f}; sourceTree = "<group>"; }};')
    groups[folder].append(f"\t\t\t\t{r} /* {f} */,")
for folder, f in sources:
    builds.append(f'\t\t{uid("build/" + folder + "/" + f)} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {uid("ref/" + folder + "/" + f)} /* {f} */; }};')

ASSETS, ASSETS_B, PLIST, PRODUCT = uid("ref/assets"), uid("build/assets"), uid("ref/plist"), uid("product")
refs.append(f'\t\t{ASSETS} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
refs.append(f'\t\t{PLIST} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
refs.append(f'\t\t{PRODUCT} /* Folio.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Folio.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
builds.append(f'\t\t{ASSETS_B} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSETS} /* Assets.xcassets */; }};')
groups["iOS"] += [f"\t\t\t\t{ASSETS} /* Assets.xcassets */,", f"\t\t\t\t{PLIST} /* Info.plist */,"]

PROJECT, TARGET, MAIN, PRODUCTS = uid("project"), uid("target"), uid("group/main"), uid("group/products")
SRC, RES, FRM = uid("phase/sources"), uid("phase/resources"), uid("phase/frameworks")
PCL, TCL, PD, PR, TD, TR = (uid(x) for x in ("cl/project", "cl/target", "cfg/pd", "cfg/pr", "cfg/td", "cfg/tr"))

def group(name):
    return f'''\t\t{uid("group/" + name)} /* {name} */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(groups[name])}
\t\t\t);
\t\t\tpath = {name};
\t\t\tsourceTree = "<group>";
\t\t}};'''

def settings(pairs): return "\n".join(f"\t\t\t\t{k} = {v};" for k, v in pairs)

project_common = [("ALWAYS_SEARCH_USER_PATHS", "NO"), ("CLANG_ENABLE_MODULES", "YES"), ("CLANG_ENABLE_OBJC_ARC", "YES"),
                  ("GCC_C_LANGUAGE_STANDARD", "gnu11"), ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"), ("SDKROOT", "iphoneos"),
                  ("SWIFT_VERSION", "5.0"), ("GCC_WARN_UNUSED_PARAMETER", "NO")]
target_common = [("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"), ("CODE_SIGN_STYLE", "Automatic"), ("CURRENT_PROJECT_VERSION", "1"),
                 ("DEVELOPMENT_TEAM", '""'), ("GENERATE_INFOPLIST_FILE", "NO"), ("INFOPLIST_FILE", "iOS/Info.plist"),
                 ("LD_RUNPATH_SEARCH_PATHS", '"$(inherited) @executable_path/Frameworks"'), ("MARKETING_VERSION", "1.0"),
                 ("OTHER_LDFLAGS", '"-lz"'), ("PRODUCT_BUNDLE_IDENTIFIER", "com.fred.folio"), ("PRODUCT_NAME", "Folio"),
                 ("SUPPORTED_PLATFORMS", '"iphoneos iphonesimulator"'), ("SUPPORTS_MACCATALYST", "NO"),
                 ("SWIFT_OBJC_BRIDGING_HEADER", '"App/Folio-Bridging-Header.h"'), ("TARGETED_DEVICE_FAMILY", '"1,2"')]

out = f'''// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(builds)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{FRM} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{MAIN} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{uid("group/iOS")} /* iOS */,
\t\t\t\t{uid("group/App")} /* App */,
\t\t\t\t{uid("group/core")} /* core */,
\t\t\t\t{PRODUCTS} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{PRODUCTS} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{PRODUCT} /* Folio.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
{group("iOS")}
{group("App")}
{group("core")}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{TARGET} /* FolioMobile */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {TCL} /* Build configuration list for PBXNativeTarget "FolioMobile" */;
\t\t\tbuildPhases = (
\t\t\t\t{SRC} /* Sources */,
\t\t\t\t{FRM} /* Frameworks */,
\t\t\t\t{RES} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = FolioMobile;
\t\t\tproductName = FolioMobile;
\t\t\tproductReference = {PRODUCT} /* Folio.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{PROJECT} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastUpgradeCheck = 2700;
\t\t\t}};
\t\t\tbuildConfigurationList = {PCL} /* Build configuration list for PBXProject "FolioMobile" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {MAIN};
\t\t\tproductRefGroup = {PRODUCTS} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{TARGET} /* FolioMobile */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{RES} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ASSETS_B} /* Assets.xcassets in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{SRC} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(f"{chr(9)*4}{uid('build/' + d + '/' + f)} /* {f} in Sources */," for d, f in sources)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{PD} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings(project_common + [("DEBUG_INFORMATION_FORMAT", "dwarf"), ("ENABLE_TESTABILITY", "YES"), ("GCC_OPTIMIZATION_LEVEL", "0"), ("ONLY_ACTIVE_ARCH", "YES"), ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"), ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"')])}
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{PR} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings(project_common + [("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'), ("GCC_OPTIMIZATION_LEVEL", "2"), ("SWIFT_COMPILATION_MODE", "wholemodule"), ("SWIFT_OPTIMIZATION_LEVEL", '"-O"'), ("VALIDATE_PRODUCT", "YES")])}
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{TD} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings(target_common)}
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{TR} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings(target_common)}
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{PCL} /* Build configuration list for PBXProject "FolioMobile" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{PD} /* Debug */,
\t\t\t\t{PR} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{TCL} /* Build configuration list for PBXNativeTarget "FolioMobile" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{TD} /* Debug */,
\t\t\t\t{TR} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {PROJECT} /* Project object */;
}}
'''
os.makedirs("FolioMobile.xcodeproj", exist_ok=True)
open("FolioMobile.xcodeproj/project.pbxproj", "w").write(out)
print("FolioMobile.xcodeproj written:", len(swift), "Swift files,", len(c), "C files")
