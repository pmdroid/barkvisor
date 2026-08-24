import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Result of a short-lived synchronous process run.
public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool {
        exitCode == 0
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

public enum PlatformProcess {
    /// Best-effort argv for a live process, or nil.
    public static func arguments(pid: Int32) -> [String]? {
        #if os(macOS)
            return darwinArguments(pid: pid)
        #elseif os(Linux)
            return linuxArguments(pid: pid)
        #else
            return nil
        #endif
    }

    /// Best-effort absolute path for a process executable, or nil.
    public static func executablePath(pid: Int32) -> String? {
        #if os(macOS)
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let ret = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard ret > 0 else { return nil }
            return String(cString: pathBuffer)
        #else
            let link = "/proc/\(pid)/exe"
            var buf = [CChar](repeating: 0, count: 4_096)
            let n = readlink(link, &buf, buf.count - 1)
            guard n > 0 else { return nil }
            return String(cString: buf)
        #endif
    }

    /// Run a **short-lived** command to completion and capture stdout/stderr.
    ///
    /// Use for: qemu-img, mkisofs/genisoimage, lsusb, ioreg, tar, `which`, etc.
    /// **Do not** use for long-lived or interactive processes (QEMU, swtpm, QMP, streaming).
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the binary.
    ///   - arguments: argv after the program name.
    ///   - timeout: Optional wall-clock timeout; process is terminated if exceeded.
    ///     Pass `nil` to wait indefinitely (prefer a bound for production call sites).
    public static func run(
        executable: URL,
        arguments: [String] = [],
        timeout: TimeInterval? = 60,
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain pipes while the process runs to avoid pipe buffer deadlock.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBox.append(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBox.append(chunk)
            }
        }

        try process.run()

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                // Brief grace period then hard-kill if still alive.
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning {
                    process.interrupt()
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw BarkVisorError.timeout(
                    "Process \(executable.lastPathComponent) timed out after \(Int(timeout))s",
                )
            }
        } else {
            process.waitUntilExit()
        }

        // Ensure handlers finish and any remaining data is collected.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let leftoverOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        let leftoverErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        if !leftoverOut.isEmpty { stdoutBox.append(leftoverOut) }
        if !leftoverErr.isEmpty { stderrBox.append(leftoverErr) }

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBox.data,
            stderr: stderrBox.data,
        )
    }

    /// Convenience: run from an absolute path string.
    public static func run(
        path: String,
        arguments: [String] = [],
        timeout: TimeInterval? = 60,
    ) throws -> CommandResult {
        try run(executable: URL(fileURLWithPath: path), arguments: arguments, timeout: timeout)
    }

    // MARK: - Helpers

    #if os(macOS)
        private static func darwinArguments(pid: Int32) -> [String]? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
                return nil
            }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
            var argc: Int32 = 0
            memcpy(&argc, buf, MemoryLayout<Int32>.size)
            guard argc > 0 else { return nil }
            var index = MemoryLayout<Int32>.size
            while index < size, buf[index] != 0 {
                index += 1
            }
            while index < size, buf[index] == 0 {
                index += 1
            }
            var args: [String] = []
            args.reserveCapacity(Int(argc))
            for _ in 0 ..< argc {
                guard index < size else { break }
                let start = index
                while index < size, buf[index] != 0 {
                    index += 1
                }
                let arg = buf.withUnsafeBufferPointer { ptr -> String in
                    guard let base = ptr.baseAddress else { return "" }
                    return String(cString: base + start)
                }
                args.append(arg)
                index += 1
            }
            return args.isEmpty ? nil : args
        }
    #endif

    #if os(Linux)
        private static func linuxArguments(pid: Int32) -> [String]? {
            let url = URL(fileURLWithPath: "/proc/\(pid)/cmdline")
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            let args = data.split(separator: 0).compactMap { chunk -> String? in
                String(data: Data(chunk), encoding: .utf8)
            }
            return args.isEmpty ? nil : args
        }
    #endif

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()

        var data: Data {
            lock.withLock { _data }
        }

        func append(_ chunk: Data) {
            lock.withLock { _data.append(chunk) }
        }
    }
}
