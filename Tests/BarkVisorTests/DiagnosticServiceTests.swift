import Foundation
import Testing
@testable import BarkVisorCore

private struct EmptyVMState: VMStateQuerying {
    func isRunning(_ vmID: String) async -> Bool {
        false
    }
    func isActiveOrStarting(_ vmID: String) async -> Bool {
        false
    }
    func allRunningVMs() async -> [String: RunningVM] {
        [:]
    }
    func vncSocketPath(for vmID: String) async -> String? {
        nil
    }
    func serialSocketPath(for vmID: String) async -> String? {
        nil
    }
    func qmpSocketPath(for vmID: String) async -> String? {
        nil
    }
}

@Suite("DiagnosticService")
struct DiagnosticServiceTests {
    @Test func `bundle includes inventory snapshot`() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "diag-data-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let expectedId = UUID()
        try Data(expectedId.uuidString.utf8).write(to: HostIdentity.fileURL(in: dir))

        // Capture around generateBundle: later tar extracts can take tens of
        // seconds on a loaded Linux runner, so current process uptime is not
        // a tight stand-in for the value written into the archive.
        let uptimeBefore = Config.processUptimeSeconds
        let archivePath = try await DiagnosticService.generateBundle(
            vmState: EmptyVMState(),
            dataDir: dir,
            version: "9.9.9-test",
        )
        let uptimeAfter = Config.processUptimeSeconds
        defer { try? FileManager.default.removeItem(atPath: archivePath) }

        #expect(FileManager.default.fileExists(atPath: archivePath))

        let listing = try PlatformProcess.run(
            path: "/usr/bin/tar",
            arguments: ["-tzf", archivePath],
            timeout: 15,
        )
        #expect(listing.succeeded)
        #expect(listing.stdoutString.contains("host-inventory.json"))
        #expect(listing.stdoutString.contains("system-info.json"))
        #expect(listing.stdoutString.contains("barkvisor-info.json"))

        let inventoryBlob = try PlatformProcess.run(
            path: "/usr/bin/tar",
            arguments: ["-xOf", archivePath, "./host-inventory.json"],
            timeout: 15,
        )
        #expect(inventoryBlob.succeeded)
        let inventory = try JSONDecoder().decode(HostInventory.self, from: inventoryBlob.stdout)
        #expect(inventory.hostId == expectedId.uuidString)
        #expect(inventory.agent.version == "9.9.9-test")

        let systemBlob = try PlatformProcess.run(
            path: "/usr/bin/tar",
            arguments: ["-xOf", archivePath, "./system-info.json"],
            timeout: 15,
        )
        #expect(systemBlob.succeeded)
        let system = try JSONSerialization.jsonObject(with: systemBlob.stdout) as? [String: Any]
        #expect(system?["hostId"] as? String == expectedId.uuidString)
        #expect(system?["platform"] as? String == inventory.platform.os)
        #expect(system?["accelerator"] as? String == inventory.virtualization.accelerator)
        #expect((system?["cpuCount"] as? NSNumber)?.intValue == inventory.resources.cpuCount)

        let appBlob = try PlatformProcess.run(
            path: "/usr/bin/tar",
            arguments: ["-xOf", archivePath, "./barkvisor-info.json"],
            timeout: 15,
        )
        #expect(appBlob.succeeded)
        let app = try JSONSerialization.jsonObject(with: appBlob.stdout) as? [String: Any]
        let reported = (app?["uptime"] as? NSNumber)?.doubleValue
        #expect(reported != nil)
        if let reported {
            #expect(reported >= 0)
            #expect(reported <= ProcessInfo.processInfo.systemUptime + 1)
            #expect(reported >= uptimeBefore - 1)
            #expect(reported <= uptimeAfter + 1)
        }
    }
}
