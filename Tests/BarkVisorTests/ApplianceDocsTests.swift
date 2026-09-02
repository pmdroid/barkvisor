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
        #expect(text.contains("auto-reverts"))
        #expect(!text.contains("### Fedora"))
        #expect(!text.contains("sudo dnf install"))
        #expect(!text.contains("cluster"))
        #expect(!text.contains("quorum"))
    }

    @Test func `networks docs apply host net and keep commands`() throws {
        let text = try read("docs/using-networks.md")
        #expect(text.contains("Apply"))
        #expect(text.contains("Revert"))
        #expect(text.contains("Keep changes"))
        #expect(text.contains("auto-reverts"))
        #expect(text.contains("POST /api/system/bridges"))
        #expect(text.contains("Keep changes"))
        #expect(text.contains("brew install socket_vmnet"))
        #expect(text.contains("Do not `sudo brew install`"))
        #expect(text.contains("DHCP"))
        #expect(text.contains("Host interfaces"))
        #expect(text.contains("VM networks"))
        #expect(text.contains("alias"))
        #expect(!text.contains("Networks → Bridge setup"))
        #expect(!text.contains("## Bridge setup"))
        #expect(!text.contains("cluster"))
        #expect(!text.contains("quorum"))
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

    @Test func `gpu passthrough docs cover intel amd vfio and occupancy`() throws {
        let text = try read("docs/getting-started-gpu-passthrough.md")
        #expect(text.contains("intel_iommu=on"))
        #expect(text.contains("amd_iommu=on"))
        #expect(text.contains("update-grub"))
        #expect(text.contains("vfio-pci"))
        #expect(text.contains("/sys/kernel/iommu_groups"))
        #expect(text.contains("blank the host display"))
        #expect(text.contains("does not block"))
        #expect(text.contains("In use by host"))
        #expect(text.contains("not a blocker"))
        #expect(text.contains("does not turn IOMMU on"))
        #expect(!text.contains("vfio-pci.ids"))
        #expect(!text.contains("cluster"))
        #expect(!text.contains("quorum"))
        #expect(text.contains("Device"))
        #expect(text.contains("Workload"))
        #expect(text.contains("Home") || text.contains("Device"))

        let linux = try read("docs/getting-started-linux.md")
        #expect(linux.contains("getting-started-gpu-passthrough.md"))
        #expect(linux.contains("does not block Attach"))

        let website = try read("website/src/content/docs/docs/guides/gpu-passthrough.md")
        #expect(website.contains("intel_iommu=on"))
        #expect(website.contains("/docs/linux/"))

        let sync = try read("website/scripts/sync-content.mjs")
        #expect(sync.contains("getting-started-gpu-passthrough.md"))
        #expect(sync.contains("guides/gpu-passthrough.md"))

        let vue = try read("frontend/src/utils/gpuPassthrough.ts")
        #expect(vue.contains("https://barkvisor.dev/docs/guides/gpu-passthrough/"))
        let consoleCopy = try read("Apps/BarkVisorConsole/Sources/Models/Models.swift")
        #expect(consoleCopy.contains("https://barkvisor.dev/docs/guides/gpu-passthrough/"))
        let attach = try read("frontend/src/views/VMDetailView.vue")
        #expect(attach.contains("GPU_PASSTHROUGH_DOCS_HREF"))
        #expect(attach.contains("IOMMU setup"))
    }

    @Test func `privilege boundary tests still forbid helper xpc`() throws {
        let text = try read("Tests/BarkVisorTests/PrivilegeBoundaryTests.swift")
        #expect(text.contains("HelperXPCClient"))
        #expect(text.contains("BarkVisorHelper"))
        #expect(text.contains("SMJobBless") || text.contains("PAS-294"))
    }
}
