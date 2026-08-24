#!/usr/bin/env python3
"""Generate BarkVisorConsole.xcodeproj (no XcodeGen required)."""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "BarkVisorConsole.xcodeproj"

APP_SOURCES = [
    "Sources/App/BarkVisorConsoleApp.swift",
    "Sources/Theme/Theme.swift",
    "Sources/Models/Models.swift",
    "Sources/Models/LibraryCatalog.swift",
    "Sources/Models/CreateWorkload.swift",
    "Sources/Models/CodingAgentImage.swift",
    "Sources/Models/CodingAgentSession.swift",
    "Sources/Models/LoginURI.swift",
    "Sources/Models/LoginOfferQR.swift",
    "Sources/Models/PairingOffer.swift",
    "Sources/Models/StreamSupport.swift",
    "Sources/Models/OllamaModels.swift",
    "Sources/Models/InferenceAPIHowTo.swift",
    "Sources/Models/InferenceHowToMint.swift",
    "Sources/Models/Chat.swift",
    "Sources/Models/APIKeys.swift",
    "Sources/Services/KeychainStore.swift",
    "Sources/Services/APIClient.swift",
    "Sources/Services/AppModel.swift",
    "Sources/Services/ConsoleSession.swift",
    "Sources/Views/RootView.swift",
    "Sources/Views/ConnectView.swift",
    "Sources/Views/LoginQRScanner.swift",
    "Sources/Views/AppShell.swift",
    "Sources/Views/SidebarView.swift",
    "Sources/Views/DashboardView.swift",
    "Sources/Views/ChatView.swift",
    "Sources/Views/HomeView.swift",
    "Sources/Views/DevicesView.swift",
    "Sources/Views/DeviceDetailView.swift",
    "Sources/Views/WorkloadsView.swift",
    "Sources/Views/CreateWorkloadSheet.swift",
    "Sources/Views/WorkloadDetailView.swift",
    "Sources/Views/SerialConsoleView.swift",
    "Sources/Views/DisplayView.swift",
    "Sources/Views/LibraryView.swift",
    "Sources/Views/ModelsView.swift",
    "Sources/Views/SettingsView.swift",
    "Sources/Views/APIKeysSection.swift",
    "Sources/Views/Components/Components.swift",
]
TEST_SOURCES = [
    "Tests/APIDecodingTests.swift",
    "Tests/LibraryCatalogTests.swift",
    "Tests/CreateWorkloadTests.swift",
    "Tests/WorkloadDetailTests.swift",
    "Tests/DeviceDetailTests.swift",
    "Tests/LocalStreamTests.swift",
    "Tests/SessionTests.swift",
    "Tests/PairingOfferTests.swift",
    "Tests/OllamaModelsTests.swift",
    "Tests/ChatTests.swift",
    "Tests/CodingAgentSessionTests.swift",
    "Tests/InferenceAPIHowToTests.swift",
    "Tests/InferenceHowToMintTests.swift",
    "Tests/PhoneTabTests.swift",
]


def uid(name: str) -> str:
    digest = hashlib.sha1(name.encode()).hexdigest().upper()
    return digest[:24]


def file_ref(path: str, extra: str = "") -> str:
    name = Path(path).name
    last = path.split(".")[-1]
    types = {
        "swift": "sourcecode.swift",
        "plist": "text.plist.xml",
        "entitlements": "text.plist.entitlements",
        "xcassets": "folder.assetcatalog",
        "md": "net.daringfireball.markdown",
    }
    ftype = types.get(last, "text")
    return (
        f"\t\t{uid('file:' + path)} /* {name} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {name}; sourceTree = \"<group>\"; {extra}}};\n"
    )


def build_file(path: str) -> str:
    name = Path(path).name
    return (
        f"\t\t{uid('build:' + path)} /* {name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {uid('file:' + path)} /* {name} */; }};\n"
    )


def group(name: str, children: list[str], path: str | None = None) -> str:
    lines = [f"\t\t{uid('group:' + name)} /* {name} */ = {{\n", "\t\t\tisa = PBXGroup;\n", "\t\t\tchildren = (\n"]
    for child in children:
        lines.append(f"\t\t\t\t{child},\n")
    lines.append("\t\t\t);\n")
    if path:
        lines.append(f"\t\t\tpath = {path};\n")
    lines.append(f"\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
    return "".join(lines)


def child_file(path: str) -> str:
    return f"{uid('file:' + path)} /* {Path(path).name} */"


def child_group(name: str) -> str:
    return f"{uid('group:' + name)} /* {name} */"


def sources_phase(name: str, paths: list[str]) -> str:
    lines = [
        f"\t\t{uid('sources:' + name)} /* Sources */ = {{\n",
        "\t\t\tisa = PBXSourcesBuildPhase;\n",
        "\t\t\tbuildActionMask = 2147483647;\n",
        "\t\t\tfiles = (\n",
    ]
    for path in paths:
        lines.append(f"\t\t\t\t{uid('build:' + path)} /* {Path(path).name} in Sources */,\n")
    lines.append("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
    return "".join(lines)


COMMON_BUILD = """
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 26.0;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = auto;
				STRING_CATALOG_GENERATE_SYMBOLS = YES;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
"""

APP_BUILD = """
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = Resources/BarkVisorConsole.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Resources/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.barkvisor.console;
				PRODUCT_NAME = BarkVisorConsole;
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_EMIT_LOC_STRINGS = YES;
"""

TEST_BUILD = """
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.barkvisor.console.tests;
				PRODUCT_NAME = BarkVisorConsoleTests;
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/BarkVisorConsole.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/BarkVisorConsole";
"""


def main() -> None:
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "xcshareddata/xcschemes").mkdir(parents=True, exist_ok=True)
    (PROJECT / "project.xcworkspace").mkdir(exist_ok=True)

    pbx: list[str] = [
        "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n\n",
        "/* Begin PBXBuildFile section */\n",
    ]
    for path in APP_SOURCES:
        pbx.append(build_file(path))
    pbx.append(
        f"\t\t{uid('build:assets')} /* Assets.xcassets in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {uid('file:Resources/Assets.xcassets')} /* Assets.xcassets */; }};\n"
    )
    pbx.append(
        f"\t\t{uid('build:Resources/noVNC')} /* noVNC in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {uid('file:Resources/noVNC')} /* noVNC */; }};\n"
    )
    pbx.append(
        f"\t\t{uid('build:SwiftTerm')} /* SwiftTerm in Frameworks */ = "
        f"{{isa = PBXBuildFile; productRef = {uid('prod:SwiftTerm')} /* SwiftTerm */; }};\n"
    )
    for path in TEST_SOURCES:
        pbx.append(build_file(path))
    pbx.append("/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */\n")
    pbx.append(
        f"\t\t{uid('file:app')} /* BarkVisorConsole.app */ = "
        "{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = BarkVisorConsole.app; sourceTree = BUILT_PRODUCTS_DIR; };\n"
    )
    pbx.append(
        f"\t\t{uid('file:tests')} /* BarkVisorConsoleTests.xctest */ = "
        "{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = BarkVisorConsoleTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };\n"
    )
    for path in APP_SOURCES + TEST_SOURCES + [
        "Resources/Info.plist",
        "Resources/BarkVisorConsole.entitlements",
        "README.md",
    ]:
        pbx.append(file_ref(path))
    pbx.append(
        f"\t\t{uid('file:Resources/Assets.xcassets')} /* Assets.xcassets */ = "
        "{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; };\n"
    )
    pbx.append(
        f"\t\t{uid('file:Resources/noVNC')} /* noVNC */ = "
        "{isa = PBXFileReference; lastKnownFileType = folder; path = noVNC; sourceTree = \"<group>\"; };\n"
    )
    pbx.append("/* End PBXFileReference section */\n\n/* Begin PBXFrameworksBuildPhase section */\n")
    pbx.append(
        f"\t\t{uid('frameworks:app')} /* Frameworks */ = {{\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{uid('build:SwiftTerm')} /* SwiftTerm in Frameworks */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
    )
    pbx.append(
        f"\t\t{uid('frameworks:tests')} /* Frameworks */ = {{\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
    )
    pbx.append("/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXGroup section */\n")
    pbx.append(
        group(
            "root",
            [
                child_group("Sources"),
                child_group("Resources"),
                child_group("Tests"),
                child_file("README.md"),
                child_group("Products"),
            ],
        )
    )
    pbx.append(
        group(
            "Products",
            [
                f"{uid('file:app')} /* BarkVisorConsole.app */",
                f"{uid('file:tests')} /* BarkVisorConsoleTests.xctest */",
            ],
        )
    )
    pbx.append(
        group(
            "Sources",
            [
                child_group("App"),
                child_group("Theme"),
                child_group("Models"),
                child_group("Services"),
                child_group("Views"),
            ],
            "Sources",
        )
    )
    pbx.append(group("App", [child_file("Sources/App/BarkVisorConsoleApp.swift")], "App"))
    pbx.append(group("Theme", [child_file("Sources/Theme/Theme.swift")], "Theme"))
    pbx.append(
        group(
            "Models",
            [
                child_file("Sources/Models/Models.swift"),
                child_file("Sources/Models/LibraryCatalog.swift"),
                child_file("Sources/Models/CreateWorkload.swift"),
                child_file("Sources/Models/CodingAgentImage.swift"),
                child_file("Sources/Models/CodingAgentSession.swift"),
                child_file("Sources/Models/LoginURI.swift"),
                child_file("Sources/Models/LoginOfferQR.swift"),
                child_file("Sources/Models/PairingOffer.swift"),
                child_file("Sources/Models/StreamSupport.swift"),
                child_file("Sources/Models/OllamaModels.swift"),
                child_file("Sources/Models/InferenceAPIHowTo.swift"),
                child_file("Sources/Models/InferenceHowToMint.swift"),
                child_file("Sources/Models/Chat.swift"),
                child_file("Sources/Models/APIKeys.swift"),
            ],
            "Models",
        )
    )
    pbx.append(
        group(
            "Services",
            [
                child_file("Sources/Services/KeychainStore.swift"),
                child_file("Sources/Services/APIClient.swift"),
                child_file("Sources/Services/AppModel.swift"),
                child_file("Sources/Services/ConsoleSession.swift"),
            ],
            "Services",
        )
    )
    pbx.append(
        group(
            "Views",
            [
                child_file("Sources/Views/RootView.swift"),
                child_file("Sources/Views/ConnectView.swift"),
                child_file("Sources/Views/LoginQRScanner.swift"),
                child_file("Sources/Views/AppShell.swift"),
                child_file("Sources/Views/SidebarView.swift"),
                child_file("Sources/Views/DashboardView.swift"),
                child_file("Sources/Views/ChatView.swift"),
                child_file("Sources/Views/HomeView.swift"),
                child_file("Sources/Views/DevicesView.swift"),
                child_file("Sources/Views/DeviceDetailView.swift"),
                child_file("Sources/Views/WorkloadsView.swift"),
                child_file("Sources/Views/CreateWorkloadSheet.swift"),
                child_file("Sources/Views/WorkloadDetailView.swift"),
                child_file("Sources/Views/SerialConsoleView.swift"),
                child_file("Sources/Views/DisplayView.swift"),
                child_file("Sources/Views/LibraryView.swift"),
                child_file("Sources/Views/ModelsView.swift"),
                child_file("Sources/Views/SettingsView.swift"),
                child_file("Sources/Views/APIKeysSection.swift"),
                child_group("Components"),
            ],
            "Views",
        )
    )
    pbx.append(group("Components", [child_file("Sources/Views/Components/Components.swift")], "Components"))
    pbx.append(
        group(
            "Resources",
            [
                f"{uid('file:Resources/Assets.xcassets')} /* Assets.xcassets */",
                f"{uid('file:Resources/noVNC')} /* noVNC */",
                child_file("Resources/Info.plist"),
                child_file("Resources/BarkVisorConsole.entitlements"),
            ],
            "Resources",
        )
    )
    pbx.append(
        group(
            "Tests",
            [
                child_file("Tests/APIDecodingTests.swift"),
                child_file("Tests/LibraryCatalogTests.swift"),
                child_file("Tests/CreateWorkloadTests.swift"),
                child_file("Tests/WorkloadDetailTests.swift"),
                child_file("Tests/DeviceDetailTests.swift"),
                child_file("Tests/LocalStreamTests.swift"),
                child_file("Tests/SessionTests.swift"),
                child_file("Tests/PairingOfferTests.swift"),
                child_file("Tests/OllamaModelsTests.swift"),
                child_file("Tests/ChatTests.swift"),
                child_file("Tests/CodingAgentSessionTests.swift"),
                child_file("Tests/InferenceAPIHowToTests.swift"),
                child_file("Tests/InferenceHowToMintTests.swift"),
                child_file("Tests/PhoneTabTests.swift"),
            ],
            "Tests",
        )
    )
    pbx.append("/* End PBXGroup section */\n\n/* Begin PBXNativeTarget section */\n")
    pbx.append(
        f"\t\t{uid('target:app')} /* BarkVisorConsole */ = {{\n"
        "\t\t\tisa = PBXNativeTarget;\n"
        "\t\t\tbuildConfigurationList = "
        f"{uid('cfgs:app')} /* Build configuration list for PBXNativeTarget \"BarkVisorConsole\" */;\n"
        "\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uid('sources:app')} /* Sources */,\n"
        f"\t\t\t\t{uid('frameworks:app')} /* Frameworks */,\n"
        f"\t\t\t\t{uid('resources:app')} /* Resources */,\n"
        "\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n"
        "\t\t\tdependencies = (\n\t\t\t);\n"
        "\t\t\tname = BarkVisorConsole;\n"
        "\t\t\tpackageProductDependencies = (\n"
        f"\t\t\t\t{uid('prod:SwiftTerm')} /* SwiftTerm */,\n"
        "\t\t\t);\n"
        "\t\t\tproductName = BarkVisorConsole;\n"
        f"\t\t\tproductReference = {uid('file:app')} /* BarkVisorConsole.app */;\n"
        "\t\t\tproductType = \"com.apple.product-type.application\";\n"
        "\t\t};\n"
    )
    pbx.append(
        f"\t\t{uid('target:tests')} /* BarkVisorConsoleTests */ = {{\n"
        "\t\t\tisa = PBXNativeTarget;\n"
        "\t\t\tbuildConfigurationList = "
        f"{uid('cfgs:tests')} /* Build configuration list for PBXNativeTarget \"BarkVisorConsoleTests\" */;\n"
        "\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uid('sources:tests')} /* Sources */,\n"
        f"\t\t\t\t{uid('frameworks:tests')} /* Frameworks */,\n"
        "\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n"
        "\t\t\tdependencies = (\n"
        f"\t\t\t\t{uid('dep:tests')} /* PBXTargetDependency */,\n"
        "\t\t\t);\n"
        "\t\t\tname = BarkVisorConsoleTests;\n"
        "\t\t\tproductName = BarkVisorConsoleTests;\n"
        f"\t\t\tproductReference = {uid('file:tests')} /* BarkVisorConsoleTests.xctest */;\n"
        "\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";\n"
        "\t\t};\n"
    )
    pbx.append("/* End PBXNativeTarget section */\n\n/* Begin PBXProject section */\n")
    pbx.append(
        f"\t\t{uid('project')} /* Project object */ = {{\n"
        "\t\t\tisa = PBXProject;\n"
        "\t\t\tattributes = {\n"
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        "\t\t\t\tLastSwiftUpdateCheck = 1600;\n"
        "\t\t\t\tLastUpgradeCheck = 1600;\n"
        "\t\t\t};\n"
        f"\t\t\tbuildConfigurationList = {uid('cfgs:project')} /* Build configuration list for PBXProject \"BarkVisorConsole\" */;\n"
        "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
        "\t\t\tdevelopmentRegion = en;\n"
        "\t\t\thasScannedForEncodings = 0;\n"
        "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
        f"\t\t\tmainGroup = {uid('group:root')} /* root */;\n"
        "\t\t\tpackageReferences = (\n"
        f"\t\t\t\t{uid('pkg:SwiftTerm')} /* XCRemoteSwiftPackageReference \"SwiftTerm\" */,\n"
        "\t\t\t);\n"
        "\t\t\tproductRefGroup = "
        f"{uid('group:Products')} /* Products */;\n"
        "\t\t\tprojectDirPath = \"\";\n"
        "\t\t\tprojectRoot = \"\";\n"
        "\t\t\ttargets = (\n"
        f"\t\t\t\t{uid('target:app')} /* BarkVisorConsole */,\n"
        f"\t\t\t\t{uid('target:tests')} /* BarkVisorConsoleTests */,\n"
        "\t\t\t);\n"
        "\t\t};\n"
    )
    pbx.append("/* End PBXProject section */\n\n/* Begin PBXResourcesBuildPhase section */\n")
    pbx.append(
        f"\t\t{uid('resources:app')} /* Resources */ = {{\n"
        "\t\t\tisa = PBXResourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{uid('build:assets')} /* Assets.xcassets in Resources */,\n"
        f"\t\t\t\t{uid('build:Resources/noVNC')} /* noVNC in Resources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
    )
    pbx.append("/* End PBXResourcesBuildPhase section */\n\n/* Begin PBXSourcesBuildPhase section */\n")
    pbx.append(sources_phase("app", APP_SOURCES))
    pbx.append(sources_phase("tests", TEST_SOURCES))
    pbx.append("/* End PBXSourcesBuildPhase section */\n\n/* Begin PBXTargetDependency section */\n")
    pbx.append(
        f"\t\t{uid('dep:tests')} /* PBXTargetDependency */ = {{\n"
        "\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {uid('target:app')} /* BarkVisorConsole */;\n"
        f"\t\t\ttargetProxy = {uid('proxy:tests')} /* PBXContainerItemProxy */;\n"
        "\t\t};\n"
    )
    pbx.append("/* End PBXTargetDependency section */\n\n/* Begin PBXContainerItemProxy section */\n")
    pbx.append(
        f"\t\t{uid('proxy:tests')} /* PBXContainerItemProxy */ = {{\n"
        "\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = {uid('project')} /* Project object */;\n"
        "\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {uid('target:app')};\n"
        "\t\t\tremoteInfo = BarkVisorConsole;\n"
        "\t\t};\n"
    )
    pbx.append("/* End PBXContainerItemProxy section */\n\n/* Begin XCBuildConfiguration section */\n")

    def xcconfig(key: str, name: str, extra: str, debug: bool) -> str:
        swift = "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";" if debug else "SWIFT_OPTIMIZATION_LEVEL = \"-O\";"
        gcc = "GCC_OPTIMIZATION_LEVEL = 0;\n\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\",);\n\t\t\t\tONLY_ACTIVE_ARCH = YES;\n\t\t\t\tENABLE_TESTABILITY = YES;" if debug else "ENABLE_NS_ASSERTIONS = NO;"
        return (
            f"\t\t{uid(key)} /* {name} */ = {{\n"
            "\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbuildSettings = {"
            f"{COMMON_BUILD}{extra}"
            f"\t\t\t\t{swift}\n"
            f"\t\t\t\t{gcc}\n"
            "\t\t\t};\n"
            f"\t\t\tname = {name};\n"
            "\t\t};\n"
        )

    pbx.append(xcconfig("cfg:project:debug", "Debug", "", True))
    pbx.append(xcconfig("cfg:project:release", "Release", "", False))
    pbx.append(xcconfig("cfg:app:debug", "Debug", APP_BUILD, True))
    pbx.append(xcconfig("cfg:app:release", "Release", APP_BUILD, False))
    pbx.append(xcconfig("cfg:tests:debug", "Debug", TEST_BUILD, True))
    pbx.append(xcconfig("cfg:tests:release", "Release", TEST_BUILD, False))
    pbx.append("/* End XCBuildConfiguration section */\n\n/* Begin XCConfigurationList section */\n")

    def cfglist(key: str, label: str, debug: str, release: str) -> str:
        return (
            f"\t\t{uid(key)} /* Build configuration list for {label} */ = {{\n"
            "\t\t\tisa = XCConfigurationList;\n"
            "\t\t\tbuildConfigurations = (\n"
            f"\t\t\t\t{uid(debug)} /* Debug */,\n"
            f"\t\t\t\t{uid(release)} /* Release */,\n"
            "\t\t\t);\n"
            "\t\t\tdefaultConfigurationIsVisible = 0;\n"
            "\t\t\tdefaultConfigurationName = Release;\n"
            "\t\t};\n"
        )

    pbx.append(cfglist("cfgs:project", "PBXProject \"BarkVisorConsole\"", "cfg:project:debug", "cfg:project:release"))
    pbx.append(cfglist("cfgs:app", "PBXNativeTarget \"BarkVisorConsole\"", "cfg:app:debug", "cfg:app:release"))
    pbx.append(cfglist("cfgs:tests", "PBXNativeTarget \"BarkVisorConsoleTests\"", "cfg:tests:debug", "cfg:tests:release"))
    pbx.append("/* End XCConfigurationList section */\n\n/* Begin XCRemoteSwiftPackageReference section */\n")
    pbx.append(
        f"\t\t{uid('pkg:SwiftTerm')} /* XCRemoteSwiftPackageReference \"SwiftTerm\" */ = {{\n"
        "\t\t\tisa = XCRemoteSwiftPackageReference;\n"
        "\t\t\trepositoryURL = \"https://github.com/migueldeicaza/SwiftTerm.git\";\n"
        "\t\t\trequirement = {\n"
        "\t\t\t\tkind = exactVersion;\n"
        "\t\t\t\tversion = 1.18.0;\n"
        "\t\t\t};\n"
        "\t\t};\n"
    )
    pbx.append("/* End XCRemoteSwiftPackageReference section */\n\n/* Begin XCSwiftPackageProductDependency section */\n")
    pbx.append(
        f"\t\t{uid('prod:SwiftTerm')} /* SwiftTerm */ = {{\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = {uid('pkg:SwiftTerm')} /* XCRemoteSwiftPackageReference \"SwiftTerm\" */;\n"
        "\t\t\tproductName = SwiftTerm;\n"
        "\t\t};\n"
    )
    pbx.append(
        "/* End XCSwiftPackageProductDependency section */\n\t};\n"
        f"\trootObject = {uid('project')} /* Project object */;\n}}\n"
    )

    project_file = PROJECT / "project.pbxproj"
    project_file.write_text("".join(pbx).replace("}};", "};"))
    (PROJECT / "project.xcworkspace/contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace\n   version = "1.0">\n'
        '   <FileRef\n      location = "self:">\n   </FileRef>\n'
        "</Workspace>\n"
    )
    (PROJECT / "xcshareddata/xcschemes/BarkVisorConsole.xcscheme").write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uid('target:app')}"
               BuildableName = "BarkVisorConsole.app"
               BlueprintName = "BarkVisorConsole"
               ReferencedContainer = "container:BarkVisorConsole.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uid('target:tests')}"
               BuildableName = "BarkVisorConsoleTests.xctest"
               BlueprintName = "BarkVisorConsoleTests"
               ReferencedContainer = "container:BarkVisorConsole.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{uid('target:app')}"
            BuildableName = "BarkVisorConsole.app"
            BlueprintName = "BarkVisorConsole"
            ReferencedContainer = "container:BarkVisorConsole.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{uid('target:app')}"
            BuildableName = "BarkVisorConsole.app"
            BlueprintName = "BarkVisorConsole"
            ReferencedContainer = "container:BarkVisorConsole.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    )
    print(f"Wrote {PROJECT}")


if __name__ == "__main__":
    main()
