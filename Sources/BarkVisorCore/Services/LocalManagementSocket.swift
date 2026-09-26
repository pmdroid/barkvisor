import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(WinSDK)
    import WinSDK
#endif

public final class LocalManagementSocketServer: @unchecked Sendable {
    public let session: LocalManagementSession
    public let bindsTCP = false
    public private(set) var boundUnixPath: String?
    private let path: String
    private let directoryMode: UInt16
    private let socketMode: UInt16
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "barkvisor.management-socket")
    private var listenFD: Int32 = -1
    private var stopped = false

    public init(
        path: String,
        session: LocalManagementSession,
        directoryMode: UInt16,
        socketMode: UInt16,
    ) {
        self.path = path
        self.session = session
        self.directoryMode = directoryMode
        self.socketMode = socketMode
    }

    public func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        lock.unlock()
        if fd >= 0 {
            #if !os(Windows)
                _ = shutdown(fd, Int32(SHUT_RDWR))
            #endif
        }
    }

    public func run() async throws {
        #if os(Windows)
            throw LocalManagementError.unavailable
        #else
            let fd = try bindUnix()
            rememberListen(fd)
            defer {
                close(fd)
                forgetListen()
                try? FileManager.default.removeItem(atPath: path)
            }
            while !isStopped {
                guard let client = try await performIO({ self.acceptClient(listen: fd) }) else { continue }
                await serve(client)
            }
        #endif
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func rememberListen(_ fd: Int32) {
        lock.lock()
        listenFD = fd
        boundUnixPath = path
        lock.unlock()
    }

    private func forgetListen() {
        lock.lock()
        listenFD = -1
        lock.unlock()
    }

    #if !os(Windows)
        private func bindUnix() throws -> Int32 {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: directoryMode)],
                ofItemAtPath: directory.path,
            )
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            let fd = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
            guard fd >= 0 else { throw LocalManagementError.unavailable }
            do {
                try LocalManagementPOSIX.bind(fd: fd, path: path)
                guard listen(fd, 16) == 0 else { throw LocalManagementError.unavailable }
                guard chmod(path, mode_t(socketMode)) == 0 else {
                    throw LocalManagementError.unavailable
                }
                let flags = fcntl(fd, F_GETFL, 0)
                guard flags >= 0 else { throw LocalManagementError.unavailable }
                guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                    throw LocalManagementError.unavailable
                }
                return fd
            } catch {
                close(fd)
                throw error
            }
        }

        private func acceptClient(listen: Int32) -> Int32? {
            var pollFD = pollfd(fd: listen, events: Int16(POLLIN), revents: 0)
            let waited = poll(&pollFD, 1, 200)
            if waited <= 0 || isStopped { return nil }
            let client = PlatformSocket.acceptBlocking(listen)
            if client < 0 { return nil }
            return client
        }

        private func serve(_ client: Int32) async {
            defer { close(client) }
            do {
                let payload = try await performIO { try LocalManagementPOSIX.readPayload(fd: client) }
                let request: LocalManagementRequest
                do {
                    request = try LocalManagementFraming.decodeRequest(payload)
                } catch {
                    let response = LocalManagementResponse(
                        requestId: "",
                        operationId: "",
                        accepted: false,
                        phase: "rejected",
                        effectCount: 0,
                        rejection: LocalRejection.malformed.rawValue,
                    )
                    try await send(response, to: client)
                    return
                }
                guard let peer = LocalManagementPOSIX.peerIdentity(fd: client) else {
                    let response = LocalManagementResponse.rejection(
                        request: request,
                        reason: .peerNotAllowed,
                    )
                    try await send(response, to: client)
                    return
                }
                let response = await session.handle(peer: peer, request: request)
                try await send(response, to: client)
            } catch LocalManagementError.payloadTooLarge {
                let response = LocalManagementResponse(
                    requestId: "",
                    operationId: "",
                    accepted: false,
                    phase: "rejected",
                    effectCount: 0,
                    rejection: LocalRejection.payloadTooLarge.rawValue,
                )
                try? await send(response, to: client)
            } catch {
                return
            }
        }

        private func send(_ response: LocalManagementResponse, to client: Int32) async throws {
            try await performIO {
                try LocalManagementPOSIX.writeFrame(fd: client, payload: LocalManagementFraming.encode(response))
            }
        }

        private func performIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                ioQueue.async { continuation.resume(with: Result(catching: operation)) }
            }
        }
    #endif
}

public enum LocalManagementSocketClient {
    public static func exchange(
        path: String,
        request: LocalManagementRequest,
    ) throws -> LocalManagementResponse {
        #if os(Windows)
            _ = path
            _ = request
            throw LocalManagementError.unavailable
        #else
            let fd = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
            guard fd >= 0 else { throw LocalManagementError.connectionLost }
            defer { close(fd) }
            try LocalManagementPOSIX.bindConnect(fd: fd, path: path)
            try LocalManagementPOSIX.writeFrame(fd: fd, payload: LocalManagementFraming.encode(request))
            let payload = try LocalManagementPOSIX.readPayload(fd: fd)
            return try LocalManagementFraming.decodeResponse(payload)
        #endif
    }
}

#if !os(Windows)
    struct LinuxPeerCredential {
        var pid: Int32 = 0
        var uid: UInt32 = 0
        var gid: UInt32 = 0
    }

    enum LocalManagementPOSIX {
        static func bind(fd: Int32, path: String) throws {
            var addr = sockaddr_un()
            try fill(&addr, path: path)
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    DarwinOrGlibc.bind(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 { throw LocalManagementError.unavailable }
        }

        static func bindConnect(fd: Int32, path: String) throws {
            var addr = sockaddr_un()
            try fill(&addr, path: path)
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 { throw LocalManagementError.connectionLost }
        }

        static func readPayload(fd: Int32) throws -> Data {
            let prefix = try readExact(fd: fd, count: 4)
            let length: Int
            do {
                length = try LocalManagementFraming.payloadLength(prefix: prefix)
            } catch {
                throw error
            }
            return try readExact(fd: fd, count: length)
        }

        static func writeFrame(fd: Int32, payload: Data) throws {
            var remaining = payload
            while !remaining.isEmpty {
                let wrote = remaining.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return send(fd, base, raw.count, Int32(MSG_NOSIGNAL))
                }
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw LocalManagementError.connectionLost
                }
                if wrote == 0 { throw LocalManagementError.connectionLost }
                remaining.removeFirst(wrote)
            }
        }

        static func peerIdentity(fd: Int32) -> LocalPeerIdentity? {
            #if os(Linux)
                var cred = LinuxPeerCredential()
                var len = socklen_t(MemoryLayout<LinuxPeerCredential>.size)
                let rc = getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len)
                guard rc == 0 else { return nil }
                return LocalPeerIdentity(uid: cred.uid, gid: cred.gid, pid: cred.pid)
            #else
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
                return LocalPeerIdentity(uid: uid, gid: gid, pid: 0)
            #endif
        }

        private static func readExact(fd: Int32, count: Int) throws -> Data {
            var data = Data()
            data.reserveCapacity(count)
            while data.count < count {
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let waited = poll(&pollFD, 1, 5_000)
                if waited == 0 { throw LocalManagementError.connectionLost }
                if waited < 0 {
                    if errno == EINTR { continue }
                    throw LocalManagementError.connectionLost
                }
                var buffer = [UInt8](repeating: 0, count: count - data.count)
                let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return read(fd, base, raw.count)
                }
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw LocalManagementError.connectionLost
                }
                if readCount == 0 { throw LocalManagementError.connectionLost }
                data.append(contentsOf: buffer.prefix(readCount))
            }
            return data
        }

        private static func fill(_ addr: inout sockaddr_un, path: String) throws {
            addr.sun_family = sa_family_t(PlatformSocket.unixFamily)
            let bytes = path.utf8CString
            guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                throw LocalManagementError.malformed
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                    bytes.withUnsafeBufferPointer { src in
                        if let base = src.baseAddress {
                            _ = memcpy(dest, base, src.count)
                        }
                    }
                }
            }
        }
    }

    private enum DarwinOrGlibc {
        static func bind(
            _ fd: Int32,
            _ addr: UnsafePointer<sockaddr>,
            _ len: socklen_t,
        ) -> Int32 {
            #if canImport(Darwin)
                Darwin.bind(fd, addr, len)
            #else
                Glibc.bind(fd, addr, len)
            #endif
        }
    }
#endif
