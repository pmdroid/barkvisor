import Foundation

public enum DiagnosticService {
    /// Generate a diagnostic bundle archive. Returns the path to the tar.gz file.
    public static func generateBundle(vmState: any VMStateQuerying) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "barkvisor-diag-\(UUID().uuidString.prefix(8))",
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // System info
        let systemInfo: [String: Any] = [
            "macOSVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpuCount": ProcessInfo.processInfo.processorCount,
            "physicalMemoryMB": ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024),
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let systemData = try JSONSerialization.data(withJSONObject: systemInfo, options: .prettyPrinted)
        try systemData.write(to: tempDir.appendingPathComponent("system-info.json"))

        // App info
        let appInfo: [String: Any] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            "uptime": ProcessInfo.processInfo.systemUptime,
            "dataDir": Config.dataDir.path,
            "logDir": "database",
        ]
        let appData = try JSONSerialization.data(withJSONObject: appInfo, options: .prettyPrinted)
        try appData.write(to: tempDir.appendingPathComponent("barkvisor-info.json"))

        // Running VMs
        let runningVMs = await vmState.allRunningVMs()
        let vmStates = runningVMs.map {
            ["id": $0.key, "pid": "\($0.value.pid)", "vncSocket": $0.value.vncSocketPath]
        }
        let vmData = try JSONSerialization.data(withJSONObject: vmStates, options: .prettyPrinted)
        try vmData.write(to: tempDir.appendingPathComponent("vm-states.json"))

        // Copy log files
        let logFiles = await LogService.shared.collectDiagnosticFiles()
        for (name, url) in logFiles {
            let dest = tempDir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try? FileManager.default.copyItem(at: url, to: dest)
        }

        // Create tar.gz
        let archiveName =
            "barkvisor-diagnostics-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).tar.gz"
        let archivePath = FileManager.default.temporaryDirectory.appendingPathComponent(archiveName)

        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProcess.arguments = ["-czf", archivePath.path, "-C", tempDir.path, "."]
        try tarProcess.run()
        tarProcess.waitUntilExit()

        guard tarProcess.terminationStatus == 0,
              FileManager.default.fileExists(atPath: archivePath.path)
        else {
            throw BarkVisorError.processSpawnFailed("Failed to create diagnostic bundle")
        }

        // Schedule cleanup after 15 minutes
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000_000)
            if FileManager.default.fileExists(atPath: archivePath.path) {
                do {
                    try FileManager.default.removeItem(at: archivePath)
                } catch {
                    Log.server.warning(
                        "Failed to clean up diagnostic bundle at \(archivePath.path): \(error)",
                    )
                }
            }
        }

        return archivePath.path
    }
}
