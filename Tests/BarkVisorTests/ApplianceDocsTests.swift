import Foundation
import Testing

/// #382: getting-started and Settings docs match the Ubuntu/Debian/Mac appliance.
struct ApplianceDocsTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func `macos install is pkg bootstrap and settings updates`() throws {
        let text = try read("docs/getting-started-installation.md")
        #expect(text.contains("Apple Silicon"))
        #expect(text.contains(".pkg"))
        #expect(text.contains("inspect, then run") || text.contains("inspect-then-run") || text.contains("less get-barkvisor.sh"))
        #expect(text.contains("get-barkvisor.sh"))
        #expect(text.contains("Settings → Updates"))
        #expect(text.contains("Do not `brew upgrade barkvisor`"))
        #expect(text.contains("Do not `sudo brew install`"))
        #expect(text.contains("brew install qemu swtpm socket_vmnet"))
        #expect(text.contains("UserName") || text.contains("root"))
        #expect(!text.contains("sudo brew services restart barkvisor"))
        #expect(!text.contains("Preferred on macOS with Homebrew"))
        #expect(!text.contains("cluster"))
        #expect(!text.contains("quorum"))
    }

    @Test func `linux install is ubuntu debian deb not fedora`() throws {
        let text = try read("docs/getting-started-linux.md")
        #expect(text.contains("Ubuntu"))
        #expect(text.contains("Debian"))
        #expect(text.contains(".deb"))
        #expect(text.contains("get-barkvisor.sh"))
        #expect(text.contains("less get-barkvisor.sh"))
        #expect(text.contains("User=root"))
        #expect(text.contains("Group=barkvisor"))
        #expect(text.contains("ProtectSystem=strict"))
        #expect(text.contains("KillMode=process"))
        #expect(text.contains("Settings → Updates"))
        #expect(text.contains("never") && text.contains("default-deleted"))
        #expect(text.contains("host timer"))
        #expect(!text.contains("### Fedora"))
        #expect(!text.contains("sudo dnf install"))
        #expect(!text.contains("cluster"))
        #expect(!text.contains("quorum"))
    }

    @Test func `networks docs apply host net and keep commands`() throws {
        let text = try read("docs/using-networks.md")
        #expect(text.contains("Apply"))
        #expect(text.contains("Revert"))
        #expect(text.contains("Device address"))
        #expect(text.contains("host timer"))
        #expect(text.contains("Wi-Fi is refused"))
        #expect(text.contains("linux-bridge-apply.sh"))
        #expect(text.contains("brew install socket_vmnet"))
        #expect(text.contains("Do not `sudo brew install`"))
        #expect(text.contains("Guest static IP"))
        #expect(text.contains("networksetup"))
        #expect(!text.contains("Setup/Start/Stop"))
        #expect(!text.contains("Setup / Start / Stop"))
        #expect(!text.contains("cluster"))
        #expect(!text.contains("quorum"))
    }

    @Test func `getting started bridge docs match linux and macos apply revert`() throws {
        let files = [
            "docs/getting-started-first-launch.md",
            "docs/getting-started-troubleshooting.md",
            "docs/getting-started-linux.md",
            "docs/getting-started-installation.md",
            "docs/using-networks.md",
            "website/src/content/docs/docs/using/networks.md",
        ]
        for relative in files {
            let text = try read(relative)
            #expect(text.contains("Bridge setup"), "\(relative) missing Bridge setup")
            #expect(text.contains("Device address"), "\(relative) missing Device address")
            #expect(text.contains("Apply"), "\(relative) missing Apply")
            #expect(text.contains("Revert") || text.contains("Apply/Revert"), "\(relative) missing Revert")
            #expect(text.contains("DHCP"), "\(relative) missing DHCP")
            #expect(!text.contains("Setup/Start/Stop"), "\(relative) still has Setup/Start/Stop")
            #expect(!text.contains("Setup / Start / Stop"), "\(relative) still has Setup / Start / Stop")
        }
        let firstLaunch = try read("docs/getting-started-first-launch.md")
        #expect(firstLaunch.contains("networksetup"))
        let troubleshooting = try read("docs/getting-started-troubleshooting.md")
        #expect(troubleshooting.contains("networksetup"))
        let changelog = try read("docs/changelog.md")
        #expect(!changelog.contains("Setup/Start/Stop"))
        let siteChange = try read("website/src/content/docs/docs/changelog.md")
        #expect(!siteChange.contains("Setup/Start/Stop"))
    }

    @Test func `settings docs include updates tab`() throws {
        let settings = try read("docs/using-settings.md")
        #expect(settings.contains("settings-updates.md"))
        #expect(settings.contains("`updates`"))
        let updates = try read("docs/settings-updates.md")
        #expect(updates.contains("Settings → Updates"))
        #expect(updates.contains(".deb"))
        #expect(updates.contains(".pkg"))
        #expect(updates.contains("Do not `brew upgrade barkvisor`"))
        #expect(updates.contains("dpkg -i"))
        #expect(updates.contains("installer -pkg"))
    }

    @Test func `privilege boundary tests still forbid helper xpc`() throws {
        let text = try read("Tests/BarkVisorTests/PrivilegeBoundaryTests.swift")
        #expect(text.contains("HelperXPCClient"))
        #expect(text.contains("BarkVisorHelper"))
        #expect(text.contains("SMJobBless") || text.contains("PAS-294"))
    }
}
