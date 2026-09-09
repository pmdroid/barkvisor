import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

/// QMP (QEMU Machine Protocol) JSON socket client
/// Not an actor — uses synchronous blocking socket I/O (metrics balloon/blockstats and QGA).
public final class QMPClient: @unchecked Sendable {
    private let socketPath: String
    private let timeoutSeconds: Int
    #if os(Windows)
        private var winSock: SOCKET = INVALID_SOCKET
    #else
        private var fd: Int32 = -1
    #endif
    /// Leftover bytes after a partial or multi-message read (QMP is newline-delimited JSON).
    private var readBuffer = Data()

    public init(socketPath: String, timeoutSeconds: Int = 3) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func connect() throws {
        try openSocket(timeoutSeconds: timeoutSeconds)

        // Read greeting and negotiate capabilities — close fd on failure
        do {
            _ = try readMessage()
            try sendCommand(["execute": "qmp_capabilities"])
            _ = try readMessage()
        } catch {
            disconnect()
            throw error
        }
    }

    /// Connect without QMP greeting/capabilities — for guest agent socket
    public func connectRaw(timeoutSeconds: Int = 2) throws {
        try openSocket(timeoutSeconds: timeoutSeconds)
    }

    private var isConnected: Bool {
        #if os(Windows)
            winSock != INVALID_SOCKET
        #else
            fd >= 0
        #endif
    }

    private func openSocket(timeoutSeconds: Int) throws {
        try PlatformSocket.ensureStarted()
        #if os(Windows)
            let created = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
            guard created != INVALID_SOCKET else {
                throw BarkVisorError.monitorError("Failed to create QMP socket")
            }
            winSock = created
            readBuffer.removeAll(keepingCapacity: false)

            var ms = DWORD(timeoutSeconds * 1_000)
            _ = withUnsafePointer(to: &ms) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) { bytes in
                    setsockopt(
                        winSock,
                        SOL_SOCKET,
                        SO_RCVTIMEO,
                        bytes,
                        Int32(MemoryLayout<DWORD>.size),
                    )
                    setsockopt(
                        winSock,
                        SOL_SOCKET,
                        SO_SNDTIMEO,
                        bytes,
                        Int32(MemoryLayout<DWORD>.size),
                    )
                }
            }

            let pathBytes = Array(socketPath.utf8CString)
            guard pathBytes.count <= 108 else {
                closeSocket()
                throw BarkVisorError.monitorError("QMP socket path too long")
            }

            var storage = [UInt8](repeating: 0, count: 2 + 108)
            let family = UInt16(bitPattern: Int16(PlatformSocket.unixFamily))
            storage.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: family, toByteOffset: 0, as: UInt16.self)
                pathBytes.withUnsafeBytes { src in
                    guard let dest = raw.baseAddress, let base = src.baseAddress else { return }
                    memcpy(dest + 2, base, src.count)
                }
            }

            let connectResult = storage.withUnsafeBytes { raw in
                WinSDK.connect(
                    winSock,
                    raw.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                    Int32(raw.count),
                )
            }

            guard connectResult == 0 else {
                closeSocket()
                throw BarkVisorError.monitorError("Failed to connect to QMP socket at \(socketPath)")
            }
        #else
            fd = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
            guard fd >= 0 else {
                throw BarkVisorError.monitorError("Failed to create QMP socket")
            }
            readBuffer.removeAll(keepingCapacity: false)

            var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(PlatformSocket.unixFamily)
            let pathBytes = socketPath.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                closeSocket()
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
                closeSocket()
                throw BarkVisorError.monitorError("Failed to connect to QMP socket at \(socketPath)")
            }
        #endif
    }

    public func execute(_ command: String) throws -> [String: Any] {
        try sendCommand(["execute": command])
        return try readCommandResponse()
    }

    public func executeWithArgs(
        _ command: String,
        args: [String: Any],
        maxResponseBytes: Int? = nil,
    ) throws -> [String: Any] {
        try sendCommand(["execute": command, "arguments": args])
        return try readCommandResponse(maxResponseBytes: maxResponseBytes)
    }

    public func disconnect() {
        closeSocket()
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func closeSocket() {
        #if os(Windows)
            if winSock != INVALID_SOCKET {
                closesocket(winSock)
                winSock = INVALID_SOCKET
            }
        #else
            if fd >= 0 {
                close(fd)
                fd = -1
            }
        #endif
    }

    /// Read the next raw message from the QMP socket (public for event listener use).
    public func readMessagePublic() throws -> [String: Any] {
        try readMessage()
    }

    /// Read a QMP command response, skipping over any asynchronous events.
    private func readCommandResponse(maxResponseBytes: Int? = nil) throws -> [String: Any] {
        while true {
            let msg = try readMessage(maxBytes: maxResponseBytes)
            // Skip asynchronous events — they have an "event" key
            if msg["event"] != nil { continue }
            return msg
        }
    }

    private func sendCommand(_ cmd: [String: Any]) throws {
        guard isConnected else {
            throw BarkVisorError.monitorError("QMP not connected")
        }
        let data = try JSONSerialization.data(withJSONObject: cmd)
        let msg = data + Data([0x0A]) // newline terminated
        var totalWritten = 0
        try msg.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            while totalWritten < buf.count {
                let n = writeSocket(base + totalWritten, buf.count - totalWritten)
                guard n > 0 else {
                    throw BarkVisorError.monitorError("QMP write failed (errno \(lastSocketError()))")
                }
                totalWritten += n
            }
        }
    }

    /// Read the next QMP JSON message (could be a response or an event).
    /// Handles multi-message reads: QEMU often sends `POWERDOWN\n{"return":{}}\n` in one packet.
    private func readMessage(maxBytes: Int? = nil) throws -> [String: Any] {
        guard isConnected else {
            throw BarkVisorError.monitorError("QMP not connected")
        }

        let chunkSize = 65_536
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        while true {
            // Complete line already buffered?
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<nl])
                readBuffer.removeSubrange(...nl)
                if line.isEmpty { continue }
                if let maxBytes, line.count > maxBytes {
                    try rejectOversizedResponse(maxBytes)
                }
                do {
                    guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw BarkVisorError.monitorError("Invalid QMP response format")
                    }
                    return json
                } catch let error as BarkVisorError {
                    throw error
                } catch {
                    throw BarkVisorError.monitorError(
                        "QMP JSON parse failed: \(error.localizedDescription)",
                    )
                }
            }

            if let maxBytes, readBuffer.count > maxBytes {
                try rejectOversizedResponse(maxBytes)
            }

            let n = readSocket(chunk, chunkSize)
            if n == 0 {
                throw BarkVisorError.monitorError("QMP connection closed (empty read)")
            }
            if n < 0 {
                if isSocketTimeout() {
                    throw BarkVisorError.monitorError("QMP read timed out after \(timeoutSeconds)s")
                }
                throw BarkVisorError.monitorError("QMP read failed (errno \(lastSocketError()))")
            }
            readBuffer.append(chunk, count: n)
            if let maxBytes, readBuffer.count > maxBytes {
                try rejectOversizedResponse(maxBytes)
            }
        }
    }

    private func writeSocket(_ buffer: UnsafeRawPointer, _ length: Int) -> Int {
        #if os(Windows)
            Int(send(winSock, buffer.assumingMemoryBound(to: CChar.self), Int32(length), 0))
        #else
            write(fd, buffer, length)
        #endif
    }

    private func readSocket(_ buffer: UnsafeMutablePointer<UInt8>, _ length: Int) -> Int {
        #if os(Windows)
            buffer.withMemoryRebound(to: CChar.self, capacity: length) { ptr in
                Int(recv(winSock, ptr, Int32(length), 0))
            }
        #else
            read(fd, buffer, length)
        #endif
    }

    private func lastSocketError() -> Int32 {
        #if os(Windows)
            WSAGetLastError()
        #else
            errno
        #endif
    }

    private func isSocketTimeout() -> Bool {
        #if os(Windows)
            let err = WSAGetLastError()
            return err == WSAETIMEDOUT || err == WSAEWOULDBLOCK
        #else
            return errno == EAGAIN || errno == EWOULDBLOCK
        #endif
    }

    /// Drop the socket so a later command cannot read a truncated tail or a
    /// leftover sibling message after we refused an oversized QMP frame.
    private func rejectOversizedResponse(_ maxBytes: Int) throws -> Never {
        disconnect()
        throw BarkVisorError.monitorError("QMP response exceeded \(maxBytes) bytes")
    }
}
