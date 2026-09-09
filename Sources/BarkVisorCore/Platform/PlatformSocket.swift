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
