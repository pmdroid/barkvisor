import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(WinSDK)
    import WinSDK
#endif

/// Portable constants / helpers for BSD vs Linux libc socket APIs.
public enum PlatformSocket {
    /// `SOCK_STREAM` as the integer type expected by `socket()` / `addrinfo.ai_socktype`.
    public static var stream: Int32 {
        #if os(Linux)
            return Int32(SOCK_STREAM.rawValue)
        #elseif os(Windows)
            return 1
        #else
            return SOCK_STREAM
        #endif
    }

    public static var datagram: Int32 {
        #if os(Linux)
            return Int32(SOCK_DGRAM.rawValue)
        #elseif os(Windows)
            return 2
        #else
            return SOCK_DGRAM
        #endif
    }

    public static var unixFamily: Int32 {
        #if os(Windows)
            return 1
        #else
            return Int32(AF_UNIX)
        #endif
    }

    public static func ensureStarted() throws {
        #if os(Windows)
            try WindowsSockets.start()
        #endif
    }

    #if os(Windows)
        public static let unixPathMax = 108

        public static func connectUnixStream(path: String) throws -> SOCKET {
            try ensureStarted()
            let created = socket(unixFamily, stream, 0)
            guard created != INVALID_SOCKET else {
                throw BarkVisorError.monitorError("Failed to create Unix socket")
            }
            do {
                try withUnixSockaddr(path: path) { addr, len in
                    let rc = WinSDK.connect(created, addr, len)
                    guard rc == 0 else {
                        throw BarkVisorError.monitorError("Failed to connect to Unix socket at \(path)")
                    }
                }
                return created
            } catch {
                closesocket(created)
                throw error
            }
        }

        static func withUnixSockaddr<R>(
            path: String,
            _ body: (UnsafePointer<sockaddr>, Int32) throws -> R,
        ) throws -> R {
            let pathBytes = Array(path.utf8CString)
            guard pathBytes.count <= unixPathMax else {
                throw BarkVisorError.monitorError("Unix socket path too long")
            }
            var storage = [UInt8](repeating: 0, count: 2 + unixPathMax)
            let family = UInt16(bitPattern: Int16(unixFamily))
            storage.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: family, toByteOffset: 0, as: UInt16.self)
                pathBytes.withUnsafeBytes { src in
                    guard let dest = raw.baseAddress, let base = src.baseAddress else { return }
                    memcpy(dest + 2, base, src.count)
                }
            }
            return try storage.withUnsafeBytes { raw in
                try body(
                    raw.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                    Int32(raw.count),
                )
            }
        }
    #endif
}

#if os(Windows)
    private enum WindowsSockets {
        private static let lock = NSLock()
        private static var started = false

        static func start() throws {
            lock.lock()
            defer { lock.unlock() }
            if started { return }
            var data = WSADATA()
            let rc = WSAStartup(0x0202, &data)
            guard rc == 0 else {
                throw BarkVisorError.monitorError("WSAStartup failed (\(rc))")
            }
            started = true
        }
    }
#endif
