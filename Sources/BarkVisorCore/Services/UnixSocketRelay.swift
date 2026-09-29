import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public final class UnixSocketRelay: @unchecked Sendable {
    public enum Listener: Sendable {
        case tcp(host: String, port: Int)
        case unix(path: String, mode: UInt16, allowedUIDs: Set<UInt32>)
    }

    private let listener: Listener
    private let destination: String
    private let destinationUID: UInt32
    private let lock = NSLock()
    private var stopped = false
    private var listening = false
    private var descriptors: Set<Int32> = []
    private var port: Int?
    public var boundPort: Int? {
        lock.withLock { port }
    }

    public init(listener: Listener, destination: String, destinationUID: UInt32) {
        self.listener = listener
        self.destination = destination
        self.destinationUID = destinationUID
    }

    public func stop() {
        lock.withLock {
            stopped = true
            #if !os(Windows)
                for fd in descriptors {
                    _ = shutdown(fd, Int32(SHUT_RDWR))
                }
            #endif
        }
    }

    public func waitUntilListening() async throws {
        while try !lock.withLock({
            if stopped { throw LocalManagementError.connectionLost }
            return listening
        }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func run() async throws {
        #if os(Windows)
            throw LocalManagementError.unavailable
        #else
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    do {
                        try self.acceptConnections()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        #endif
    }

    #if !os(Windows)
        private func register(_ fd: Int32) -> Bool {
            lock.withLock {
                guard !stopped, descriptors.count < 257 else { return false }
                descriptors.insert(fd)
                return true
            }
        }

        private func release(_ fd: Int32) {
            lock.withLock {
                descriptors.remove(fd)
                close(fd)
            }
        }

        private func acceptConnections() throws {
            let fd: Int32
            switch listener {
            case let .tcp(host, port):
                fd = socket(AF_INET, PlatformSocket.stream, 0)
                guard fd >= 0 else { throw LocalManagementError.unavailable }
                var reuse: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(port).bigEndian
                address.sin_addr = in_addr(s_addr: inet_addr(host))
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard result == 0 else {
                    close(fd)
                    throw LocalManagementError.unavailable
                }
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
                }
                lock.withLock { self.port = Int(UInt16(bigEndian: address.sin_port)) }
            case let .unix(path, mode, _):
                fd = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
                guard fd >= 0 else { throw LocalManagementError.unavailable }
                do {
                    if FileManager.default.fileExists(atPath: path) {
                        try FileManager.default.removeItem(atPath: path)
                    }
                    try LocalManagementPOSIX.bind(fd: fd, path: path)
                    guard chmod(path, mode_t(mode)) == 0 else { throw LocalManagementError.unavailable }
                } catch {
                    close(fd)
                    throw error
                }
            }
            guard register(fd) else {
                close(fd)
                return
            }
            defer {
                release(fd)
                if case let .unix(path, _, _) = listener { try? FileManager.default.removeItem(atPath: path) }
            }
            guard listen(fd, 128) == 0 else { throw LocalManagementError.unavailable }
            try prepare(fd)
            lock.withLock { listening = true }
            while !lock.withLock({ stopped }) {
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 200) > 0 else { continue }
                let incoming = PlatformSocket.acceptBlocking(fd)
                guard incoming >= 0 else { continue }
                guard fcntl(incoming, F_SETFD, FD_CLOEXEC) == 0 else {
                    close(incoming)
                    continue
                }
                if case let .unix(_, _, allowed) = listener {
                    guard let peer = LocalManagementPOSIX.peerIdentity(fd: incoming), allowed.contains(peer.uid) else {
                        close(incoming)
                        continue
                    }
                }
                guard register(incoming) else {
                    close(incoming)
                    continue
                }
                Thread.detachNewThread { self.forward(incoming) }
            }
        }

        private func prepare(_ fd: Int32) throws {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw LocalManagementError.unavailable
            }
        }

        private func forward(_ incoming: Int32) {
            defer { release(incoming) }
            let outgoing = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
            guard outgoing >= 0 else { return }
            guard fcntl(outgoing, F_SETFD, FD_CLOEXEC) == 0 else {
                close(outgoing)
                return
            }
            guard register(outgoing) else {
                close(outgoing)
                return
            }
            defer { release(outgoing) }
            do {
                try LocalManagementPOSIX.bindConnect(fd: outgoing, path: destination)
                guard let peer = LocalManagementPOSIX.peerIdentity(fd: outgoing), peer.uid == destinationUID else { return }
                try prepare(incoming)
                try prepare(outgoing)
                try pump(incoming, outgoing)
            } catch {
                return
            }
        }

        private func pump(_ first: Int32, _ second: Int32) throws {
            let sockets = [first, second]
            var pending = [Data(), Data()]
            var ended = [false, false]
            var halfClosed = [false, false]
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while !lock.withLock({ stopped }) {
                for i in 0 ..< 2 where ended[i] && pending[1 - i].isEmpty && !halfClosed[i] {
                    _ = shutdown(sockets[1 - i], Int32(SHUT_WR))
                    halfClosed[i] = true
                }
                if halfClosed.allSatisfy(\.self) { return }
                var ready = (0 ..< 2).map { i in
                    pollfd(
                        fd: ended[i] && pending[i].isEmpty ? -1 : sockets[i],
                        events: (ended[i] || pending[1 - i].count >= 65_536 ? 0 : Int16(POLLIN))
                            | (pending[i].isEmpty ? 0 : Int16(POLLOUT)),
                        revents: 0,
                    )
                }
                let count = poll(&ready, 2, 200)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw LocalManagementError.connectionLost
                }
                for i in 0 ..< 2 {
                    if ready[i].revents & Int16(POLLERR | POLLNVAL) != 0 { return }
                    if ready[i].revents & Int16(POLLOUT) != 0, !pending[i].isEmpty {
                        let written = pending[i].withUnsafeBytes { raw -> Int in
                            guard let base = raw.baseAddress else { return 0 }
                            return send(sockets[i], base, raw.count, Int32(MSG_NOSIGNAL))
                        }
                        if written > 0 { pending[i].removeFirst(written) }
                        else if written == 0 || (errno != EAGAIN && errno != EINTR) { return }
                    }
                    if !ended[i], ready[i].revents & Int16(POLLIN | POLLHUP) != 0,
                       pending[1 - i].count < 65_536 {
                        let readCount = read(sockets[i], &buffer, buffer.count)
                        if readCount > 0 { pending[1 - i].append(contentsOf: buffer.prefix(readCount)) }
                        else if readCount == 0 { ended[i] = true }
                        else if errno != EAGAIN, errno != EINTR { return }
                    }
                }
            }
        }
    #endif
}
