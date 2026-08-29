import Foundation
import Testing
@testable import BarkVisorCore

/// #383: uninstall / postrm strip tagged host-bridge files and never drop shared br0.
struct UninstallTaggedBridgeTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func makeFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-uninstall-\(UUID().uuidString)")
        let fm = FileManager.default
        for sub in [
            "etc/qemu",
            "etc/netplan",
            "etc/systemd/network",
            "etc/NetworkManager/system-connections",
            "etc/barkvisor",
            "var/lib/barkvisor",
        ] {
            try fm.createDirectory(
                at: dir.appendingPathComponent(sub),
                withIntermediateDirectories: true,
            )
        }
        let acl = """
        allow virbr0
        # barkvisor:allow-br0
        allow br0
        allow shared0
        """
        try acl.write(
            to: dir.appendingPathComponent("etc/qemu/bridge.conf"),
            atomically: true,
            encoding: .utf8,
        )
        try """
        # managed-by: barkvisor
        network:
          version: 2
        """.write(
            to: dir.appendingPathComponent("etc/netplan/90-barkvisor-br0.yaml"),
            atomically: true,
            encoding: .utf8,
        )
        try """
        network:
          version: 2
          ethernets:
            eth0:
              dhcp4: true
        """.write(
            to: dir.appendingPathComponent("etc/netplan/00-installer-config.yaml"),
            atomically: true,
            encoding: .utf8,
        )
        try """
        # managed-by: barkvisor
        [NetDev]
        Name=br0
        Kind=bridge
        """.write(
            to: dir.appendingPathComponent("etc/systemd/network/90-barkvisor-br0.netdev"),
            atomically: true,
            encoding: .utf8,
        )
        try """
        [NetDev]
        Name=br0
        Kind=bridge
        """.write(
            to: dir.appendingPathComponent("etc/systemd/network/10-shared-br0.netdev"),
            atomically: true,
            encoding: .utf8,
        )
        try """
        [connection]
        id=barkvisor-br0
        """.write(
            to: dir.appendingPathComponent(
                "etc/NetworkManager/system-connections/barkvisor-br0.nmconnection",
            ),
            atomically: true,
            encoding: .utf8,
        )
        try """
        {"bridge":"br0","createdBridge":true}
        """.write(
            to: dir.appendingPathComponent("var/lib/barkvisor/host-bridge-br0.json"),
            atomically: true,
            encoding: .utf8,
        )
        try "BARKVISOR_PORT=7777\n".write(
            to: dir.appendingPathComponent("etc/barkvisor/barkvisor.env"),
            atomically: true,
            encoding: .utf8,
        )
        return dir
    }

    private func run(
        _ url: URL,
        args: [String],
        env: [String: String],
        executable: String = "/bin/sh",
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [url.path] + args
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in env {
            merged[key] = value
        }
        process.environment = merged
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        )
    }

    private func hostEnv(_ root: URL, extra: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [
            "BARKVISOR_HOST_ROOT": root.path,
            "BARKVISOR_SKIP_NMCLI": "1",
            "BARKVISOR_DRY_RUN": "1",
        ]
        extra.forEach { env[$0.key] = $0.value }
        return env
    }

    @Test func `ACL strip is marker-tagged and leaves foreign allows`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = repoRoot.appendingPathComponent("scripts/lib/tagged-bridge-cleanup.sh")
        let result = try run(lib, args: ["--strip-tagged"], env: hostEnv(root))
        #expect(result.exitCode == 0, "strip exit \(result.exitCode): \(result.stderr)")
        let acl = try String(
            contentsOf: root.appendingPathComponent("etc/qemu/bridge.conf"),
            encoding: .utf8,
        )
        #expect(!acl.contains(LinuxHostBridgeApply.aclMarker))
        #expect(!acl.contains("allow br0"))
        #expect(acl.contains("allow virbr0"))
        #expect(acl.contains("allow shared0"))
    }

    @Test func `tagged netplan and NM files are removed; untagged stay`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = repoRoot.appendingPathComponent("scripts/lib/tagged-bridge-cleanup.sh")
        let result = try run(lib, args: ["--strip-tagged"], env: hostEnv(root))
        #expect(result.exitCode == 0, "strip exit \(result.exitCode): \(result.stderr)")
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/netplan/90-barkvisor-br0.yaml").path,
            ),
        )
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/netplan/00-installer-config.yaml").path,
            ),
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/systemd/network/90-barkvisor-br0.netdev").path,
            ),
        )
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/systemd/network/10-shared-br0.netdev").path,
            ),
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "etc/NetworkManager/system-connections/barkvisor-br0.nmconnection",
                ).path,
            ),
        )
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("var/lib/barkvisor").path),
        )
    }

    @Test func `default cleanup never deletes br0`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = repoRoot.appendingPathComponent("scripts/lib/tagged-bridge-cleanup.sh")
        let result = try run(lib, args: ["--offer"], env: hostEnv(root))
        #expect(result.exitCode == 0, "offer exit \(result.exitCode): \(result.stderr)")
        #expect(result.stdout.contains("never default-deleted"))
        #expect(result.stdout.contains("--remove-bridge"))
        #expect(!result.stdout.contains("ip link delete"))
        #expect(!result.stderr.contains("ip link delete"))
    }

    @Test func `remove-bridge without created marker refuses`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("var/lib/barkvisor/host-bridge-br0.json"),
        )
        let lib = repoRoot.appendingPathComponent("scripts/lib/tagged-bridge-cleanup.sh")
        let result = try run(lib, args: ["--remove-bridge"], env: hostEnv(root))
        #expect(result.exitCode == 5)
        #expect(result.stderr.contains("Will not delete a shared bridge"))
        #expect(!result.stdout.contains("ip link delete"))
    }

    @Test func `remove-bridge with created marker is offered not default`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = repoRoot.appendingPathComponent("scripts/lib/tagged-bridge-cleanup.sh")
        let dry = try run(lib, args: ["--remove-bridge"], env: hostEnv(root))
        #expect(dry.exitCode == 0, "remove-bridge exit \(dry.exitCode): \(dry.stderr)")
        #expect(dry.stdout.contains("would ip link delete br0"))
    }

    @Test func `uninstall --purge offers bridge removal and keeps data-dir message`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = repoRoot.appendingPathComponent("scripts/uninstall.sh")
        let result = try run(
            script,
            args: ["--purge"],
            env: hostEnv(root),
            executable: "/bin/bash",
        )
        #expect(result.exitCode == 0, "uninstall --purge exit \(result.exitCode): \(result.stderr)\n\(result.stdout)")
        #expect(result.stdout.contains("never default-deleted"))
        #expect(result.stdout.contains("--remove-bridge"))
        #expect(!result.stdout.contains("brew uninstall"))
        let acl = try String(
            contentsOf: root.appendingPathComponent("etc/qemu/bridge.conf"),
            encoding: .utf8,
        )
        #expect(acl.contains("allow virbr0"))
        #expect(!acl.contains("allow br0"))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("var/lib/barkvisor").path,
            ),
        )
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/netplan/00-installer-config.yaml").path,
            ),
        )
    }

    @Test func `uninstall --revert offers and keeps appliance data`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = repoRoot.appendingPathComponent("scripts/uninstall.sh")
        let result = try run(
            script,
            args: ["--revert"],
            env: hostEnv(root),
            executable: "/bin/bash",
        )
        #expect(result.exitCode == 0, "uninstall --revert exit \(result.exitCode): \(result.stderr)\n\(result.stdout)")
        #expect(result.stdout.contains("--remove-bridge"))
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("var/lib/barkvisor").path),
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/netplan/90-barkvisor-br0.yaml").path,
            ),
        )
    }

    @Test func `postrm remove strips tags and keeps data and shared netplan`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let postrm = repoRoot.appendingPathComponent("packaging/linux/debian/postrm")
        let result = try run(postrm, args: ["remove"], env: hostEnv(root))
        #expect(result.exitCode == 0, "postrm remove exit \(result.exitCode): \(result.stderr)")
        let acl = try String(
            contentsOf: root.appendingPathComponent("etc/qemu/bridge.conf"),
            encoding: .utf8,
        )
        #expect(!acl.contains("allow br0"))
        #expect(acl.contains("allow virbr0"))
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("var/lib/barkvisor").path),
        )
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/barkvisor/barkvisor.env").path,
            ),
        )
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/systemd/network/10-shared-br0.netdev").path,
            ),
        )
        #expect(!result.stdout.contains("ip link delete"))
    }

    @Test func `postrm purge offers and still refuses default br0 delete`() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let postrm = repoRoot.appendingPathComponent("packaging/linux/debian/postrm")
        let result = try run(postrm, args: ["purge"], env: hostEnv(root))
        #expect(result.exitCode == 0, "postrm purge exit \(result.exitCode): \(result.stderr)")
        #expect(result.stdout.contains("never default-deleted"))
        #expect(result.stdout.contains("BARKVISOR_REMOVE_BRIDGE=1"))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/barkvisor/barkvisor.env").path,
            ),
        )
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("var/lib/barkvisor").path),
        )
    }

    @Test func `scripts stay inside tagged cleanup and leftover helper`() throws {
        let uninstall = try read("scripts/uninstall.sh")
        let postrm = try read("packaging/linux/debian/postrm")
        let lib = try read("scripts/lib/tagged-bridge-cleanup.sh")

        for body in [uninstall, postrm, lib] {
            #expect(body.contains("/var/lib/barkvisor"))
            #expect(!body.contains("HelperXPCClient"))
            #expect(!body.contains("SMJobBless"))
            #expect(!body.localizedCaseInsensitiveContains("cluster"))
            #expect(!body.localizedCaseInsensitiveContains("quorum"))
        }

        #expect(uninstall.contains("lib/tagged-bridge-cleanup.sh"))
        #expect(uninstall.contains("dev.barkvisor.helper"))
        #expect(uninstall.contains("dev.barkvisor.bridge."))
        #expect(uninstall.contains("--remove-bridge"))
        #expect(uninstall.contains("--uninstall-socket-vmnet"))
        #expect(uninstall.contains("brew services stop socket_vmnet"))
        #expect(!uninstall.contains("sudo brew"))
        #expect(uninstall.contains("brew uninstall socket_vmnet"))
        #expect(uninstall.contains("because --uninstall-socket-vmnet was passed"))
        #expect(uninstall.contains("leftover _barkvisor"))
        #expect(uninstall.contains("Appliance data preserved"))

        for tagged in [postrm, lib] {
            #expect(tagged.contains("# barkvisor:allow-br0"))
            #expect(tagged.contains("# managed-by: barkvisor"))
        }
        #expect(postrm.contains("BARKVISOR_REMOVE_BRIDGE"))
        #expect(postrm.contains("ip link delete"))
        #expect(lib.contains("LinuxHostBridgeApply.aclMarker") || lib.contains("barkvisor:allow-br0"))
    }

    @Test func `apply markers match cleanup tokens`() {
        #expect(LinuxHostBridgeApply.aclMarker == "# barkvisor:allow-br0")
        #expect(LinuxHostBridgeApply.netplanYAML(
            bridge: "br0",
            nic: "eth0",
            addressing: .dhcp,
            address: nil,
            gateway: nil,
            dns: [],
        ).contains("# managed-by: barkvisor"))
    }
}
