import Foundation
import Testing
@testable import BarkVisorCore

struct InAppUpdateEligibilityTests {
    private func appliance(
        os: String,
        hostArch: String = "arm64",
        isRoot: Bool = true,
        isInstalledLayout: Bool = true,
        dataDirIsVarLib: Bool = true,
        dataDirOverridden: Bool = false,
        prefix: String = "/usr/local",
        executablePath: String = "/usr/local/bin/barkvisor",
        debianFamily: Bool = true,
        dpkgPresent: Bool = true,
    ) -> InAppUpdateFacts {
        InAppUpdateFacts(
            isRoot: isRoot,
            isInstalledLayout: isInstalledLayout,
            dataDirIsVarLib: dataDirIsVarLib,
            dataDirOverridden: dataDirOverridden,
            hostArch: hostArch,
            os: os,
            installPrefix: prefix,
            executablePath: executablePath,
            debianFamily: debianFamily,
            dpkgPresent: dpkgPresent,
        )
    }

    @Test func `ubuntu root appliance is deb`() {
        let facts = appliance(os: "Linux", hostArch: "x86_64")
        #expect(InAppUpdateEligibility.evaluate(facts))
        #expect(InAppUpdateEligibility.packageKind(for: facts) == .deb)
    }

    @Test func `apple silicon pkg appliance is pkg`() {
        let facts = appliance(os: "macOS", debianFamily: false, dpkgPresent: false)
        #expect(InAppUpdateEligibility.evaluate(facts))
        #expect(InAppUpdateEligibility.packageKind(for: facts) == .pkg)
    }

    @Test func `swift run and smoke fail closed`() {
        #expect(!InAppUpdateEligibility.evaluate(appliance(os: "Linux", isInstalledLayout: false)))
        #expect(!InAppUpdateEligibility.evaluate(appliance(os: "macOS", isInstalledLayout: false)))
        #expect(!InAppUpdateEligibility.evaluate(appliance(os: "Linux", dataDirOverridden: true)))
        #expect(!InAppUpdateEligibility.evaluate(appliance(os: "Linux", dataDirIsVarLib: false)))
        #expect(!InAppUpdateEligibility.evaluate(appliance(os: "Linux", isRoot: false)))
    }

    @Test func `homebrew keg is not the update channel`() {
        let brew = appliance(
            os: "macOS",
            prefix: "/opt/homebrew",
            executablePath: "/opt/homebrew/bin/barkvisor",
            debianFamily: false,
            dpkgPresent: false,
        )
        #expect(InAppUpdateEligibility.isHomebrewKeg(
            prefix: brew.installPrefix,
            executablePath: brew.executablePath,
        ))
        #expect(!InAppUpdateEligibility.evaluate(brew))
        #expect(InAppUpdateEligibility.isHomebrewKeg(
            prefix: "/usr/local",
            executablePath: "/opt/homebrew/Cellar/barkvisor/1.0.0/bin/barkvisor",
        ))
    }

    @Test func `fedora rpm and intel mac are out of scope`() {
        #expect(!InAppUpdateEligibility.evaluate(
            appliance(os: "Linux", debianFamily: false, dpkgPresent: false),
        ))
        #expect(!InAppUpdateEligibility.evaluate(
            appliance(os: "Linux", debianFamily: false, dpkgPresent: true),
        ))
        #expect(!InAppUpdateEligibility.evaluate(
            appliance(os: "macOS", hostArch: "x86_64", debianFamily: false, dpkgPresent: false),
        ))
        #expect(!InAppUpdateEligibility.evaluate(appliance(os: "Windows")))
    }

    @Test func `os-release debian family`() {
        #expect(InAppUpdateEligibility.isDebianFamily(osRelease: "ID=ubuntu\nID_LIKE=debian\n"))
        #expect(InAppUpdateEligibility.isDebianFamily(osRelease: "ID=debian\n"))
        #expect(InAppUpdateEligibility.isDebianFamily(osRelease: "ID=\"linuxmint\"\nID_LIKE=\"ubuntu debian\"\n"))
        #expect(!InAppUpdateEligibility.isDebianFamily(osRelease: "ID=fedora\nID_LIKE=\"rhel fedora\"\n"))
        #expect(!InAppUpdateEligibility.isDebianFamily(osRelease: ""))
    }

    @Test func `deb arch follows host arch`() {
        #expect(InAppUpdateEligibility.linuxDebArch(hostArch: "x86_64") == "amd64")
        #expect(InAppUpdateEligibility.linuxDebArch(hostArch: "amd64") == "amd64")
        #expect(InAppUpdateEligibility.linuxDebArch(hostArch: "arm64") == "arm64")
        #expect(InAppUpdateEligibility.linuxDebArch(hostArch: "aarch64") == "arm64")
    }

    @Test func `appliance data dir accepts private var`() {
        #expect(InAppUpdateEligibility.isApplianceDataDir("/var/lib/barkvisor"))
        #expect(InAppUpdateEligibility.isApplianceDataDir("/private/var/lib/barkvisor"))
        #expect(!InAppUpdateEligibility.isApplianceDataDir("/tmp/barkvisor-smoke"))
    }

    @Test func `live facts on this process are not an appliance`() {
        let facts = InAppUpdateEligibility.liveFacts()
        #expect(!InAppUpdateEligibility.evaluate(facts))
        #expect(PlatformCapabilities.supportsInAppUpdate == false)
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireInAppUpdate()
        }
    }
}
