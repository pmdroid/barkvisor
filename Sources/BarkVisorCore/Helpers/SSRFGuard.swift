import Foundation

/// SSRF protection utilities for validating URLs against private/internal hosts.
public enum SSRFGuard {
    /// Check if a hostname string matches a private/internal IP range or known private hostname.
    /// This is the fast-path check that does not perform DNS resolution.
    public static func isPrivateHost(_ host: String) -> Bool {
        // Block well-known private hostnames
        if host == "localhost" || host.hasSuffix(".local") || host == "metadata.google.internal"
            || host.hasSuffix(".internal") {
            return true
        }

        // Block private/reserved IPv4 ranges
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            let (a, b) = (parts[0], parts[1])
            if a == 0 { return true } // 0.0.0.0/8 (current network)
            if a == 10 { return true } // 10.0.0.0/8
            if a == 127 { return true } // 127.0.0.0/8 (loopback)
            if a == 172, b >= 16, b <= 31 { return true } // 172.16.0.0/12
            if a == 192, b == 168 { return true } // 192.168.0.0/16
            if a == 169, b == 254 { return true } // 169.254.0.0/16 (link-local)
            if a >= 224 { return true } // 224.0.0.0/4 multicast + 240.0.0.0/4 reserved
        }

        // Block IPv6 loopback/private — normalize bracket-stripped form
        let lower = host.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .lowercased()
        if lower == "::1" || lower == "0:0:0:0:0:0:0:1" || lower == "::" { return true }
        // Check for IPv6-mapped IPv4 addresses (e.g., ::ffff:127.0.0.1)
        if lower.hasPrefix("::ffff:") {
            let mapped = String(lower.dropFirst(7))
            let mappedParts = mapped.split(separator: ".").compactMap { UInt8($0) }
            if mappedParts.count == 4 {
                return isPrivateHost(mapped)
            }
        }
        // Check first hex group for private ranges
        let firstGroup = lower.split(separator: ":").first.map(String.init) ?? ""
        if firstGroup.hasPrefix("fc") || firstGroup.hasPrefix("fd") { return true } // ULA (fc00::/7)
        if firstGroup == "fe80" { return true } // Link-local (fe80::/10)

        return false
    }

    /// Check if a hostname resolves to any private/internal IP via DNS.
    /// Performs actual DNS resolution to defend against DNS rebinding attacks
    /// where a public hostname (e.g., evil.com) resolves to a private IP (e.g., 127.0.0.1).
    public static func resolvesToPrivateIP(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC // both IPv4 and IPv6
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let addrList = result else {
            // Resolution failed — treat as safe to let the caller handle the network error.
            return false
        }
        defer { freeaddrinfo(addrList) }

        var current: UnsafeMutablePointer<addrinfo>? = addrList
        while let info = current {
            if let ipString = ipStringFromAddrInfo(info.pointee) {
                if isPrivateHost(ipString) {
                    return true
                }
            }
            current = info.pointee.ai_next
        }

        return false
    }

    /// Validate a URL, checking both the hostname string and resolved IPs.
    /// Returns a descriptive error string if the URL targets a private host, or nil if safe.
    public static func validate(url: URL) -> String? {
        guard let host = url.host?.lowercased() else {
            return "URL has no host"
        }

        // Fast path: check hostname string directly
        if isPrivateHost(host) {
            return "URL targets a private/internal host: \(host)"
        }

        // Slow path: resolve DNS and check all resulting IPs
        if resolvesToPrivateIP(host) {
            return "URL hostname '\(host)' resolves to a private/internal IP address"
        }

        return nil
    }

    // MARK: - Private helpers

    private static func ipStringFromAddrInfo(_ info: addrinfo) -> String? {
        switch info.ai_family {
        case AF_INET:
            guard let addr = info.ai_addr else { return nil }
            var sin = sockaddr_in()
            memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = sin.sin_addr
            inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
            return buf.withUnsafeBufferPointer {
                String(decoding: $0.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
            }
        case AF_INET6:
            guard let addr = info.ai_addr else { return nil }
            var sin6 = sockaddr_in6()
            memcpy(&sin6, addr, MemoryLayout<sockaddr_in6>.size)
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var in6Addr = sin6.sin6_addr
            inet_ntop(AF_INET6, &in6Addr, &buf, socklen_t(INET6_ADDRSTRLEN))
            return buf.withUnsafeBufferPointer {
                String(decoding: $0.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
            }
        default:
            return nil
        }
    }
}
