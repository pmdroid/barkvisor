import Foundation

/// QMP (QEMU Machine Protocol) JSON socket client
/// Not an actor — uses synchronous blocking socket I/O, called from within MetricsCollector
public final class QMPClient: @unchecked Sendable {
    private let socketPath: String
    private let timeoutSeconds: Int
    private var fd: Int32 = -1

    public init(socketPath: String, timeoutSeconds: Int = 3) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func connect() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BarkVisorError.monitorError("Failed to create QMP socket")
        }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            fd = -1
            throw BarkVisorError.monitorError("QMP socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        _ = memcpy(dest, base, src.count)
                    }
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Foundation.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            close(fd)
            fd = -1
            throw BarkVisorError.monitorError("Failed to connect to QMP socket at \(socketPath)")
        }

        // Read greeting and negotiate capabilities — close fd on failure
        do {
            _ = try readMessage()
            try sendCommand(["execute": "qmp_capabilities"])
            _ = try readMessage()
        } catch {
            close(fd)
            fd = -1
            throw error
        }
    }

    /// Connect without QMP greeting/capabilities — for guest agent socket
    public func connectRaw(timeoutSeconds: Int = 2) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BarkVisorError.monitorError("Failed to create socket")
        }

        // Set read/write timeout so we don't block forever if guest agent is unresponsive
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            fd = -1
            throw BarkVisorError.monitorError("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        _ = memcpy(dest, base, src.count)
                    }
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Foundation.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            close(fd)
            fd = -1
            throw BarkVisorError.monitorError("Failed to connect to socket at \(socketPath)")
        }
    }

    public func execute(_ command: String) throws -> [String: Any] {
        try sendCommand(["execute": command])
        return try readCommandResponse()
    }

    public func executeWithArgs(_ command: String, args: [String: Any]) throws -> [String: Any] {
        try sendCommand(["execute": command, "arguments": args])
        return try readCommandResponse()
    }

    /// Wait for a specific QMP event type (e.g. "DEVICE_DELETED").
    /// Reads messages until the event arrives or the socket timeout expires.
    /// Any command responses received while waiting are discarded.
    public func waitForEvent(_ eventType: String, timeout: TimeInterval = 5) throws -> [String: Any] {
        // Temporarily set a longer timeout for event waiting
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        defer {
            // Restore original timeout
            var original = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &original, socklen_t(MemoryLayout<timeval>.size))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let msg: [String: Any]
            do {
                msg = try readMessage()
            } catch {
                // Socket read timed out — keep waiting until deadline
                if case let BarkVisorError.monitorError(m) = error, m.contains("timed out") {
                    continue
                }
                throw error
            }
            if let event = msg["event"] as? String, event == eventType {
                return msg
            }
            // Not our event — keep reading (could be another event or stale response)
        }
        throw BarkVisorError.monitorError("Timed out waiting for QMP event: \(eventType)")
    }

    public func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Read the next raw message from the QMP socket (public for event listener use).
    public func readMessagePublic() throws -> [String: Any] {
        try readMessage()
    }

    /// Read a QMP command response, skipping over any asynchronous events.
    private func readCommandResponse() throws -> [String: Any] {
        while true {
            let msg = try readMessage()
            // Skip asynchronous events — they have an "event" key
            if msg["event"] != nil { continue }
            return msg
        }
    }

    private func sendCommand(_ cmd: [String: Any]) throws {
        guard fd >= 0 else {
            throw BarkVisorError.monitorError("QMP not connected")
        }
        let data = try JSONSerialization.data(withJSONObject: cmd)
        let msg = data + Data([0x0A]) // newline terminated
        var totalWritten = 0
        try msg.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            while totalWritten < buf.count {
                let n = write(fd, base + totalWritten, buf.count - totalWritten)
                guard n > 0 else {
                    throw BarkVisorError.monitorError("QMP write failed (errno \(errno))")
                }
                totalWritten += n
            }
        }
    }

    /// Read the next QMP JSON message (could be a response or an event).
    private func readMessage() throws -> [String: Any] {
        guard fd >= 0 else {
            throw BarkVisorError.monitorError("QMP not connected")
        }

        var buffer = Data()
        let chunkSize = 65_536
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        // Read until we get a complete JSON line (newline terminated)
        // Responses can be large (e.g. guest-network-get-interfaces), so keep reading
        while true {
            let n = read(fd, chunk, chunkSize)
            if n == 0 { break }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw BarkVisorError.monitorError("QMP read timed out after \(timeoutSeconds)s")
                }
                throw BarkVisorError.monitorError("QMP read failed (errno \(errno))")
            }
            buffer.append(chunk, count: n)
            // Check if the last byte(s) contain a newline — complete response
            if buffer.last == 0x0A { break }
        }

        guard !buffer.isEmpty else {
            throw BarkVisorError.monitorError("QMP connection closed (empty read)")
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
                throw BarkVisorError.monitorError("Invalid QMP response format")
            }
            return json
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw BarkVisorError.monitorError("QMP JSON parse failed: \(error.localizedDescription)")
        }
    }
}
