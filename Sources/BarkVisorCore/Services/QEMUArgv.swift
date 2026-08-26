import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct QEMUArgv: Equatable, Sendable {
    public typealias ProcessEntry = (pid: Int32, arguments: [String])

    public let arguments: [String]

    public init?(arguments: [String]) {
        guard arguments.contains(where: Self.isQEMUExecutable) else { return nil }
        self.arguments = arguments
    }

    public static func isQEMUExecutable(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.hasPrefix("qemu-system")
    }

    public var uuid: String? {
        values(after: "-uuid").first
    }

    public var guestName: String? {
        values(after: "-name").first
    }

    public var qmpSocketPaths: [String] {
        values(after: "-qmp").compactMap(Self.unixSocketPath)
    }

    public var vncSocketPath: String? {
        values(after: "-vnc").compactMap(Self.unixSocketPath).first
    }

    public var serialSocketPath: String? {
        for spec in values(after: "-chardev") {
            let parts = spec.split(separator: ",").map(String.init)
            guard parts.contains("id=serial0") else { continue }
            if let path = parts.compactMap(Self.chardevPath).first {
                return path
            }
        }
        return nil
    }

    public var driveFilePaths: [String] {
        values(after: "-drive").compactMap(Self.driveFilePath)
    }

    public enum ReconnectAction: Equatable, Sendable {
        case cleanupDead
        case dropStalePidFile
        case adopt
    }

    public static func reconnectDecision(
        pidAlive: Bool,
        executableIsQEMU: Bool,
        argvUUID: String?,
        vmID: String,
    ) -> ReconnectAction {
        guard pidAlive else { return .cleanupDead }
        guard executableIsQEMU else { return .dropStalePidFile }
        guard let argvUUID else { return .adopt }
        return argvUUID.caseInsensitiveCompare(vmID) == .orderedSame ? .adopt : .dropStalePidFile
    }

    public static func reportsWriteLock(_ stderr: String) -> Bool {
        stderr.contains("Failed to get \"write\" lock")
            || stderr.contains("Is another process using the image")
    }

    public enum DiskHolder: Equatable, Sendable {
        case selfProcess(pid: Int32)
        case foreign(pid: Int32, guestName: String?)
    }

    public static func diskHolder(
        diskPaths: [String],
        vmID: String,
        processes: [ProcessEntry],
    ) -> DiskHolder? {
        guard !diskPaths.isEmpty else { return nil }
        var selfPid: Int32?
        var foreign: DiskHolder?
        for entry in processes {
            guard let argv = QEMUArgv(arguments: entry.arguments), usesDisk(argv, diskPaths) else {
                continue
            }
            let owned = argv.uuid.map { $0.caseInsensitiveCompare(vmID) == .orderedSame } ?? false
            if owned {
                selfPid = entry.pid
            } else if foreign == nil {
                foreign = .foreign(pid: entry.pid, guestName: argv.guestName)
            }
        }
        if let selfPid {
            return .selfProcess(pid: selfPid)
        }
        return foreign
    }

    static func usesDisk(_ argv: QEMUArgv, _ diskPaths: [String]) -> Bool {
        let drives = Set(argv.driveFilePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return diskPaths.contains { disk in
            drives.contains(URL(fileURLWithPath: disk).standardizedFileURL.path)
        }
    }

    private func values(after flag: String) -> [String] {
        var result: [String] = []
        var index = 1
        while index < arguments.count {
            if arguments[index] == flag, index + 1 < arguments.count {
                result.append(arguments[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    static func unixSocketPath(_ spec: String) -> String? {
        guard spec.hasPrefix("unix:") else { return nil }
        let rest = spec.dropFirst("unix:".count)
        guard let path = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first, !path.isEmpty
        else {
            return nil
        }
        return String(path)
    }

    private static func chardevPath(_ part: String) -> String? {
        guard part.hasPrefix("path=") else { return nil }
        let path = String(part.dropFirst("path=".count))
        return path.isEmpty ? nil : path
    }

    private static func driveFilePath(_ spec: String) -> String? {
        guard let token = spec.split(separator: ",").map(String.init).first(where: {
            $0.hasPrefix("file=")
        }) else { return nil }
        let path = String(token.dropFirst("file=".count))
        return path.isEmpty ? nil : path
    }
}

public enum QEMUProcessTable {
    public static func qemuProcesses() -> [QEMUArgv.ProcessEntry] {
        pids().compactMap { pid in
            guard let argv = PlatformProcess.arguments(pid: pid),
                  QEMUArgv(arguments: argv) != nil
            else { return nil }
            return (pid: pid, arguments: argv)
        }
    }

    private static func pids() -> [Int32] {
        #if os(Linux)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
                return []
            }
            return entries.compactMap { Int32($0) }.filter { $0 > 1 }
        #else
            guard let result = try? PlatformProcess.run(
                path: "/bin/ps",
                arguments: ["-axww", "-o", "pid="],
                timeout: 5,
            ), result.succeeded
            else { return [] }
            return result.stdoutString.split(whereSeparator: \.isNewline)
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 > 1 }
        #endif
    }
}
