import Foundation

/// Sends HMP commands to QEMU via its monitor unix socket
public struct QEMUMonitor {
    public let socketPath: String

    public func send(_ command: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BarkVisorError.monitorError(
                "Failed to create socket: \(String(cString: strerror(errno)))",
            )
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw BarkVisorError.monitorError("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw BarkVisorError.monitorError(
                "Failed to connect to monitor socket: \(String(cString: strerror(errno)))",
            )
        }

        // Read the initial prompt
        _ = try readUntil(fd: fd, prompt: "(qemu) ", timeout: 3.0)

        // Send command — ensure all bytes are written
        let cmdData = Data("\(command)\n".utf8)
        var totalWritten = 0
        while totalWritten < cmdData.count {
            let written = cmdData.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return write(fd, base + totalWritten, ptr.count - totalWritten)
            }
            guard written > 0 else {
                throw BarkVisorError.monitorError(
                    "Write failed after \(totalWritten)/\(cmdData.count) bytes: \(String(cString: strerror(errno)))",
                )
            }
            totalWritten += written
        }

        // Read response
        return try readUntil(fd: fd, prompt: "(qemu) ", timeout: 5.0)
    }

    public func powerdown() throws {
        _ = try send("system_powerdown")
    }

    public func quit() throws {
        _ = try send("quit")
    }

    private func readUntil(fd: Int32, prompt: String, timeout: TimeInterval) throws -> String {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)

        while Date() < deadline {
            let remaining = max(Int32(deadline.timeIntervalSinceNow * 1_000), 1)
            let ret = poll(&pollFd, 1, remaining)
            if ret <= 0 { break }

            var chunk = [UInt8](repeating: 0, count: 4_096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0 ..< n])

            if let str = String(data: buffer, encoding: .utf8), str.hasSuffix(prompt) {
                return String(str.dropLast(prompt.count))
            }
        }

        return String(data: buffer, encoding: .utf8) ?? ""
    }

    public init(socketPath: String) {
        self.socketPath = socketPath
    }
}
