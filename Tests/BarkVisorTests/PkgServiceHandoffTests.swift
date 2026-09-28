import Foundation
import Testing

struct PkgServiceHandoffTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let value = try #require(attributes[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data(text.utf8).write(to: url)
    }

    private func run(
        _ script: URL,
        args: [String] = [],
        env: [String: String],
    ) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        var merged = ProcessInfo.processInfo.environment
        env.forEach { merged[$0.key] = $0.value }
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

    private func stage(_ root: URL) throws {
        let launchd = root.appendingPathComponent("Library/LaunchDaemons")
        try FileManager.default.createDirectory(at: launchd, withIntermediateDirectories: true)
        for name in ["dev.barkvisor.daemon.plist", "dev.barkvisor.server.plist"] {
            let source = repoRoot.appendingPathComponent("Resources/\(name)")
            try FileManager.default.copyItem(at: source, to: launchd.appendingPathComponent(name))
        }
        try write(
            "<plist>dev.barkvisor</plist>\n",
            to: launchd.appendingPathComponent("dev.barkvisor.plist"),
        )
        let data = root.appendingPathComponent("var/lib/barkvisor")
        try write("disk\n", to: data.appendingPathComponent("disks/vm.qcow2"))
        try write("1\n", to: data.appendingPathComponent("pids/vm.pid"))
        try write("secret\n", to: data.appendingPathComponent("authority/management.key"))
        try write("db\n", to: data.appendingPathComponent("db.sqlite"))
        try write("transport\n", to: data.appendingPathComponent("agent/device.key"))
        try write("1\n", to: data.appendingPathComponent("schema-version"))
    }

    @Test func `package jobs name BarkDaemon and BarkServer`() throws {
        let daemon = try read("Resources/dev.barkvisor.daemon.plist")
        let server = try read("Resources/dev.barkvisor.server.plist")
        let build = try read("scripts/build-release.sh")
        #expect(daemon.contains("<string>BarkDaemon</string>"))
        #expect(daemon.contains("<string>daemon</string>"))
        #expect(daemon.contains("<key>AbandonProcessGroup</key>"))
        #expect(daemon.contains("<string>barkvisor</string>"))
        #expect(!daemon.contains("<key>UserName</key>"))
        #expect(server.contains("<string>BarkServer</string>"))
        #expect(server.contains("<key>UserName</key>"))
        #expect(server.contains("<string>barkvisor</string>"))
        #expect(server.contains("<string>server</string>"))
        #expect(server.contains("/usr/local/bin/barkvisor"))
        #expect(!server.contains("<key>AbandonProcessGroup</key>"))
        #expect(build.contains("dev.barkvisor.daemon.plist"))
        #expect(build.contains("dev.barkvisor.server.plist"))
        #expect(!build.contains("Resources/dev.barkvisor.plist"))
        #expect(!FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Resources/dev.barkvisor.plist").path))
    }

    @Test func `handoff retires the combined job and keeps workload files`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bv-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root)
        let script = repoRoot.appendingPathComponent("scripts/pkg-service-handoff.sh")
        let result = try run(script, env: ["BARKVISOR_HOST_ROOT": root.path])
        #expect(result.0 == 0, "\(result.1)\n\(result.2)")
        let launchd = root.appendingPathComponent("Library/LaunchDaemons")
        #expect(!FileManager.default.fileExists(atPath: launchd.appendingPathComponent("dev.barkvisor.plist").path))
        #expect(FileManager.default.fileExists(atPath: launchd.appendingPathComponent("dev.barkvisor.daemon.plist").path))
        #expect(FileManager.default.fileExists(atPath: launchd.appendingPathComponent("dev.barkvisor.server.plist").path))
        let data = root.appendingPathComponent("var/lib/barkvisor")
        #expect(try String(contentsOf: data.appendingPathComponent("disks/vm.qcow2"), encoding: .utf8) == "disk\n")
        #expect(try String(contentsOf: data.appendingPathComponent("pids/vm.pid"), encoding: .utf8) == "1\n")
        #expect(try mode(data.appendingPathComponent("db.sqlite").path) == 0o600)
        #expect(try mode(data.appendingPathComponent("authority/management.key").path) == 0o600)
        #expect(try mode(data.appendingPathComponent("agent/device.key").path) == 0o640)
        #expect(try mode(root.appendingPathComponent("var/run/barkvisor/management").path) == 0o750)
        let account = try String(contentsOf: root.appendingPathComponent("Users/barkvisor"), encoding: .utf8)
        #expect(account.contains("/usr/bin/false"))
        let log = try String(contentsOf: data.appendingPathComponent("service-handoff.log"), encoding: .utf8)
        let retired = try #require(log.range(of: "bootout dev.barkvisor"))
        let daemon = try #require(log.range(of: "bootstrap BarkDaemon"))
        let server = try #require(log.range(of: "bootstrap BarkServer"))
        #expect(retired.lowerBound < daemon.lowerBound)
        #expect(daemon.lowerBound < server.lowerBound)
        #expect(log.components(separatedBy: "bootstrap BarkDaemon").count == 2)
        #expect(log.components(separatedBy: "bootstrap BarkServer").count == 2)
        let outcome = try String(contentsOf: data.appendingPathComponent("update-outcome.json"), encoding: .utf8)
        #expect(outcome.contains("\"status\":\"succeeded\""))
        let scriptText = try read("scripts/pkg-service-handoff.sh")
        #expect(!scriptText.contains("pkill"))
        #expect(!scriptText.contains("killall"))
    }

    @Test func `newer schema stops before the combined job is retired`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bv-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root)
        try write("2\n", to: root.appendingPathComponent("var/lib/barkvisor/schema-version"))
        let script = repoRoot.appendingPathComponent("scripts/pkg-service-handoff.sh")
        let result = try run(script, env: ["BARKVISOR_HOST_ROOT": root.path])
        #expect(result.0 != 0)
        #expect(result.2.contains("unsupported downgrade"))
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Library/LaunchDaemons/dev.barkvisor.plist").path,
            ),
        )
        #expect(try String(contentsOf: root.appendingPathComponent("var/lib/barkvisor/disks/vm.qcow2"), encoding: .utf8) == "disk\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Users/barkvisor").path))
    }

    @Test func `failed health is recorded and is not a successful handoff`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bv-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root)
        let script = repoRoot.appendingPathComponent("scripts/pkg-service-handoff.sh")
        let result = try run(
            script,
            env: ["BARKVISOR_HOST_ROOT": root.path, "BARKVISOR_PKG_HEALTH": "fail"],
        )
        #expect(result.0 != 0)
        let outcome = try String(
            contentsOf: root.appendingPathComponent("var/lib/barkvisor/update-outcome.json"),
            encoding: .utf8,
        )
        #expect(outcome.contains("\"status\":\"failed\""))
        #expect(try String(contentsOf: root.appendingPathComponent("var/lib/barkvisor/disks/vm.qcow2"), encoding: .utf8) == "disk\n")
    }

    @Test func `uninstall removes both jobs and keeps data unless purged`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bv-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root)
        let uninstall = repoRoot.appendingPathComponent("scripts/uninstall.sh")
        let kept = try run(
            uninstall,
            env: [
                "BARKVISOR_HOST_ROOT": root.path,
                "BARKVISOR_SKIP_NMCLI": "1",
                "BARKVISOR_DRY_RUN": "1",
            ],
        )
        #expect(kept.0 == 0, "\(kept.1)\n\(kept.2)")
        let launchd = root.appendingPathComponent("Library/LaunchDaemons")
        #expect(!FileManager.default.fileExists(atPath: launchd.appendingPathComponent("dev.barkvisor.daemon.plist").path))
        #expect(!FileManager.default.fileExists(atPath: launchd.appendingPathComponent("dev.barkvisor.server.plist").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("var/lib/barkvisor/disks/vm.qcow2").path))
        try stage(root)
        let purged = try run(
            uninstall,
            args: ["--purge"],
            env: [
                "BARKVISOR_HOST_ROOT": root.path,
                "BARKVISOR_SKIP_NMCLI": "1",
                "BARKVISOR_DRY_RUN": "1",
            ],
        )
        #expect(purged.0 == 0, "\(purged.1)\n\(purged.2)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("var/lib/barkvisor/disks/vm.qcow2").path))
    }
}
