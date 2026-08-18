import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A live `qemu-system-*` process that belongs to a Workload (`-uuid`).
public struct QEMUProcessRecord: Equatable, Sendable {
    public var pid: Int32
    public var vmID: String
    public var serialSocketPath: String
    public var vncSocketPath: String
    public var qmpSocketPath: String
    public var qmpEventSocketPath: String

    public init(
        pid: Int32,
        vmID: String,
        serialSocketPath: String,
        vncSocketPath: String,
        qmpSocketPath: String,
        qmpEventSocketPath: String,
    ) {
        self.pid = pid
        self.vmID = vmID
        self.serialSocketPath = serialSocketPath
        self.vncSocketPath = vncSocketPath
        self.qmpSocketPath = qmpSocketPath
        self.qmpEventSocketPath = qmpEventSocketPath
    }

    /// Parse QEMU argv (`-uuid`, `-qmp unix:…`, `-vnc unix:…`, `-chardev path=`).
    /// First `-qmp` is the command socket; the second is the event socket.
    public static func parse(pid: Int32, arguments: [String]) -> QEMUProcessRecord? {
        let isQEMU = arguments.contains { arg in
            let base = URL(fileURLWithPath: arg).lastPathComponent
            return base.hasPrefix("qemu-system")
        }
        guard isQEMU else { return nil }

        var uuid: String?
        var vnc = ""
        var serial = ""
        var qmp: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "-uuid", index + 1 < arguments.count {
                uuid = arguments[index + 1]
                index += 2
                continue
            }
            if arg == "-vnc", index + 1 < arguments.count {
                if let path = unixSocketPath(arguments[index + 1]) {
                    vnc = path
                }
                index += 2
                continue
            }
            if arg == "-qmp", index + 1 < arguments.count {
                if let path = unixSocketPath(arguments[index + 1]) {
                    qmp.append(path)
                }
                index += 2
                continue
            }
            if arg == "-chardev", index + 1 < arguments.count {
                let spec = arguments[index + 1]
                if let path = chardevPath(spec),
                   spec.contains("id=serial0") || path.contains("-ser.sock") {
                    serial = path
                }
                index += 2
                continue
            }
            index += 1
        }
        guard let uuid, !uuid.isEmpty else { return nil }
        return QEMUProcessRecord(
            pid: pid,
            vmID: uuid,
            serialSocketPath: serial,
            vncSocketPath: vnc,
            qmpSocketPath: qmp.first ?? "",
            qmpEventSocketPath: qmp.count > 1 ? qmp[1] : "",
        )
    }

    static func unixSocketPath(_ spec: String) -> String? {
        guard spec.hasPrefix("unix:") else { return nil }
        let rest = spec.dropFirst("unix:".count)
        guard let path = rest.split(separator: ",", maxSplits: 1).first, !path.isEmpty else {
            return nil
        }
        return String(path)
    }

    static func chardevPath(_ spec: String) -> String? {
        for part in spec.split(separator: ",") where part.hasPrefix("path=") {
            let path = String(part.dropFirst("path=".count))
            return path.isEmpty ? nil : path
        }
        return nil
    }
}

/// Find a running QEMU that already owns a Workload, even when the pid file
/// is stale or sockets moved (PrivateTmp / socket-dir cutover).
public enum QEMUProcessLocator {
    public static func find(vmID: String) -> QEMUProcessRecord? {
        let needle = vmID.lowercased()
        return listRunning().first { $0.vmID.lowercased() == needle }
    }

    public static func listRunning() -> [QEMUProcessRecord] {
        #if os(Linux)
            return listFromProc()
        #else
            return listFromPS()
        #endif
    }

    public static func commandLine(pid: Int32) -> [String]? {
        #if os(Linux)
            return linuxCommandLine(pid: pid)
        #else
            return nil
        #endif
    }

    #if os(Linux)
        private static func listFromProc() -> [QEMUProcessRecord] {
            let proc = URL(fileURLWithPath: "/proc", isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: proc.path) else {
                return []
            }
            var found: [QEMUProcessRecord] = []
            for name in names {
                guard let pid = Int32(name), pid > 0 else { continue }
                guard let args = linuxCommandLine(pid: pid),
                      let record = QEMUProcessRecord.parse(pid: pid, arguments: args)
                else { continue }
                found.append(record)
            }
            return found
        }

        private static func linuxCommandLine(pid: Int32) -> [String]? {
            let url = URL(fileURLWithPath: "/proc/\(pid)/cmdline")
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return data.split(separator: 0, omittingEmptySubsequences: true).compactMap { slice in
                String(data: Data(slice), encoding: .utf8)
            }
        }
    #endif

    #if !os(Linux)
        private static func listFromPS() -> [QEMUProcessRecord] {
            let result: CommandResult
            do {
                result = try PlatformProcess.run(
                    path: "/bin/ps",
                    arguments: ["-axww", "-o", "pid=", "-o", "command="],
                    timeout: 5,
                )
            } catch {
                return []
            }
            guard result.succeeded else { return [] }
            var found: [QEMUProcessRecord] = []
            for line in result.stdoutString.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let space = trimmed.firstIndex(where: \.isWhitespace) else { continue }
                guard let pid = Int32(trimmed[..<space]) else { continue }
                let command = trimmed[space...].trimmingCharacters(in: .whitespaces)
                guard command.contains("qemu-system") else { continue }
                let args = command.split(separator: " ").map(String.init)
                if let record = QEMUProcessRecord.parse(pid: pid, arguments: args) {
                    found.append(record)
                }
            }
            return found
        }
    #endif
}
