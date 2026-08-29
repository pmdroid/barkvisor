import Foundation
import Testing

/// #386: Device daemon is root; QEMU must not inherit that from the unit.
struct RootDaemonPackagingTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func `linux units run as root and keep KillMode process`() throws {
        for relative in [
            "packaging/linux/barkvisor.service",
            "packaging/linux/barkvisor-agent.service",
            "Resources/barkvisor.service",
            "Resources/barkvisor-agent.service",
        ] {
            let unit = try read(relative)
            #expect(unit.contains("User=root"), "\(relative) must be root")
            #expect(!unit.contains("User=barkvisor"), "\(relative) must not run as barkvisor")
            #expect(unit.contains("KillMode=process"), "\(relative) must not SIGTERM QEMU")
            #expect(!unit.contains("KillMode=control-group"))
            #expect(unit.contains("ProtectSystem=strict"))
            #expect(unit.contains("-/etc/netplan"))
            #expect(unit.contains("-/etc/NetworkManager"))
            #expect(unit.contains("-/etc/qemu"))
            #expect(unit.contains("-/etc/systemd/network"))
            #expect(unit.contains("-/usr/lib/qemu/qemu-bridge-helper"))
            #expect(unit.contains("-/usr/libexec/qemu-bridge-helper"))
            #expect(unit.contains("-/usr/local/libexec/qemu/qemu-bridge-helper"))
            #expect(unit.contains("RuntimeDirectoryMode=0770"))
            #expect(unit.contains("Group=barkvisor"))
        }
    }

    @Test func `macos appliance plist is root without _barkvisor`() throws {
        let plist = try read("Resources/dev.barkvisor.plist")
        #expect(!plist.contains("<key>UserName</key>"))
        #expect(!plist.contains("<key>GroupName</key>"))
        #expect(!plist.contains("_barkvisor"))
        #expect(plist.contains("<key>AbandonProcessGroup</key>"))
        #expect(!plist.contains("barkvisor.helper"))
    }

    @Test func `pkg postinstall does not create _barkvisor`() throws {
        let script = try read("scripts/postinstall.sh")
        #expect(!script.contains("BARKVISOR_USER="))
        #expect(!script.contains("dscl"))
        #expect(!script.contains("_barkvisor"))
        #expect(script.contains("/var/lib/barkvisor"))
        #expect(script.contains("launchctl bootstrap system /Library/LaunchDaemons/dev.barkvisor.plist"))
        #expect(script.contains("dev.barkvisor.helper"))
    }
}
