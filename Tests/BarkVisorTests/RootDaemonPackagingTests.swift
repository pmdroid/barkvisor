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
            #expect(unit.contains("ConfigurationDirectory=qemu"))
            #expect(unit.contains("-/etc/systemd/network"))
            #expect(unit.contains("-/usr/lib/qemu/qemu-bridge-helper"))
            #expect(unit.contains("-/usr/libexec/qemu-bridge-helper"))
            #expect(unit.contains("-/usr/local/libexec/qemu/qemu-bridge-helper"))
            #expect(unit.contains("RuntimeDirectoryMode=0770"))
            #expect(unit.contains("UMask=0007"))
            #expect(unit.contains("Group=barkvisor"))
        }
    }

    @Test func `linux packaging creates etc qemu before the unit starts`() throws {
        let postinst = try read("packaging/linux/debian/postinst")
        #expect(postinst.contains("install -d -m 0755 /etc/qemu"))
        let qemuDir = try #require(postinst.range(of: "install -d -m 0755 /etc/qemu"))
        let restart = try #require(postinst.range(of: "try-restart barkvisor.service"))
        #expect(qemuDir.lowerBound < restart.lowerBound)

        let spec = try read("packaging/linux/rpm/barkvisor.spec.in")
        #expect(spec.contains("install -d -m 0755 /etc/qemu"))
        #expect(spec.contains("%dir /etc/qemu"))

        let arch = try read("packaging/linux/arch/barkvisor.install")
        #expect(arch.contains("install -d -m 0755 /etc/qemu"))

        let stage = try read("scripts/lib/linux-package-stage.sh")
        #expect(stage.contains("\"$stage/etc/qemu\""))

        let tarball = try read("scripts/build-linux-packages.sh")
        #expect(tarball.contains("install -d -m 0755 /etc/qemu"))

        let sourceInstall = try read("scripts/install-linux.sh")
        #expect(sourceInstall.contains("/etc/qemu"))
    }

    @Test func `linux device unit can apply a deb in-process`() throws {
        for relative in [
            "packaging/linux/barkvisor.service",
            "Resources/barkvisor.service",
        ] {
            let unit = try read(relative)
            #expect(unit.contains("ProtectSystem=strict"), "\(relative)")
            #expect(unit.contains("/usr/local"), "\(relative) must allow dpkg to write the payload")
            #expect(unit.contains("/var/lib/dpkg"), "\(relative) must allow the dpkg database")
            #expect(unit.contains("/var/cache/apt"), "\(relative) must allow apt-get -f")
            #expect(
                !unit.contains("ReadOnlyPaths=/usr/local/share/barkvisor"),
                "\(relative) must not keep the .deb payload read-only",
            )
        }
    }

    @Test func `prerm does not stop barkvisor on upgrade`() throws {
        let prerm = try read("packaging/linux/debian/prerm")
        guard let upgradeRange = prerm.range(of: "upgrade)"),
              let removeRange = prerm.range(of: "remove|deconfigure")
        else {
            Issue.record("prerm must split upgrade from remove|deconfigure")
            return
        }
        #expect(upgradeRange.lowerBound < removeRange.lowerBound)
        let upgradeBody = String(prerm[upgradeRange.upperBound ..< removeRange.lowerBound])
        #expect(!upgradeBody.contains("stop barkvisor.service"))
        #expect(upgradeBody.contains("stop_agent") || upgradeBody.contains("barkvisor-agent.service"))
        let removeBody = String(prerm[removeRange.upperBound...])
        #expect(removeBody.contains("stop barkvisor.service") || removeBody.contains("stop_units"))
        #expect(prerm.contains("systemctl stop barkvisor.service"))
    }

    @Test func `linux packaging installs vfio udev rule and drop-user groups`() throws {
        let rules = try read("packaging/linux/udev/99-barkvisor-vfio.rules")
        #expect(rules == "SUBSYSTEM==\"vfio\", GROUP=\"kvm\", MODE=\"0660\"\n")

        let stage = try read("scripts/lib/linux-package-stage.sh")
        #expect(stage.contains("/usr/lib/udev/rules.d/99-barkvisor-vfio.rules"))

        let postinst = try read("packaging/linux/debian/postinst")
        #expect(postinst.contains("usermod -aG vfio barkvisor"))
        #expect(postinst.contains("udevadm trigger --subsystem-match=vfio"))
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
