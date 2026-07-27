import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Portable constants / helpers for BSD vs Linux libc socket APIs.
public enum PlatformSocket {
    /// `SOCK_STREAM` as the integer type expected by `socket()` / `addrinfo.ai_socktype`.
    public static var stream: Int32 {
        #if os(Linux)
            return Int32(SOCK_STREAM.rawValue)
        #else
            return SOCK_STREAM
        #endif
    }
}
