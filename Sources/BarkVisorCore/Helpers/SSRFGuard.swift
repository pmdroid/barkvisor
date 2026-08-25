#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
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
        // Link-local fe80::/10 — first 10 bits 1111111010 (fe80–febf).
        if let group = UInt16(firstGroup, radix: 16), group & 0xFFC0 == 0xFE80 { return true }

        return false
    }

    /// Resolve a hostname to canonical IP strings (IPv4 and IPv6).
    /// Returns an empty array when DNS fails so the caller can decide policy.
    public static func resolvedIPStrings(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC // both IPv4 and IPv6
        hints.ai_socktype = PlatformSocket.stream

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let addrList = result else {
            return []
        }
        defer { freeaddrinfo(addrList) }

        var ips: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = addrList
        while let info = current {
            if let ipString = ipStringFromAddrInfo(info.pointee) {
                ips.append(ipString)
            }
            current = info.pointee.ai_next
        }
        return ips
    }

    /// Check if a hostname resolves to any private/internal IP via DNS.
    /// Performs actual DNS resolution to defend against DNS rebinding attacks
    /// where a public hostname (e.g., evil.com) resolves to a private IP (e.g., 127.0.0.1).
    public static func resolvesToPrivateIP(_ host: String) -> Bool {
        resolvedIPStrings(host).contains { isPrivateHost($0) }
    }

    /// Validate a URL, checking both the hostname string and resolved IPs.
    /// Returns a descriptive error string if the URL targets a private host, or nil if safe.
    public static func validate(url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
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

    /// Scheme allowlist plus ``validate(url:)``. Catalog/remote input must never
    /// claim the local `file://` download path.
    public static func fetchRejection(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), Config.allowedURLSchemes.contains(scheme) else {
            return "Invalid URL. Only http:// and https:// URLs are allowed."
        }
        return validate(url: url)
    }

    public static func fetchRejection(for url: URL, allowedHosts: Set<String>) -> String? {
        if let reason = fetchRejection(for: url) {
            return reason
        }
        let host = url.host?.lowercased() ?? ""
        if host.isEmpty {
            return "URL has no host"
        }
        if !allowedHosts.contains(host) {
            return "URL host '\(host)' is not allowed"
        }
        return nil
    }

    /// Resolve once and pick a single public IP for the TCP connect.
    /// TLS SNI and the HTTP Host header stay on `originalHost`.
    public static func pinEndpoint(url: URL, resolvedIPs: [String]? = nil) throws -> PinnedEndpoint {
        guard let scheme = url.scheme?.lowercased(), Config.allowedURLSchemes.contains(scheme) else {
            throw SSRFPinError.rejected("Invalid URL. Only http:// and https:// URLs are allowed.")
        }
        guard let host = url.host, !host.isEmpty else {
            throw SSRFPinError.rejected("URL has no host")
        }
        if let reason = validate(url: url) {
            throw SSRFPinError.rejected(reason)
        }
        let ips = resolvedIPs ?? resolvedIPStrings(host)
        if ips.isEmpty {
            throw SSRFPinError.rejected("URL hostname '\(host)' could not be resolved")
        }
        if ips.contains(where: { isPrivateHost($0) }) {
            throw SSRFPinError.rejected(
                "URL hostname '\(host)' resolves to a private/internal IP address",
            )
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return PinnedEndpoint(
            originalHost: host, connectIP: ips[0], port: port, usesTLS: scheme == "https",
        )
    }

    /// Absolute URL for an HTTP redirect hop, or nil when the status is not a hop.
    public static func redirectTarget(
        statusCode: Int,
        location: String?,
        from requestURL: URL,
    ) -> URL? {
        switch statusCode {
        case 301, 302, 303, 307, 308:
            break
        default:
            return nil
        }
        guard let location, !location.isEmpty else { return nil }
        return URL(string: location, relativeTo: requestURL)?.absoluteURL
    }

    /// Whether a redirect hop may be fetched. Default URLSession follows blindly;
    /// Library downloads must re-run ``validate(url:)`` (scheme + DNS) on Location.
    public static func shouldFollowRedirect(to url: URL, allowedHosts: Set<String>? = nil) -> Bool {
        if let allowedHosts {
            return fetchRejection(for: url, allowedHosts: allowedHosts) == nil
        }
        return fetchRejection(for: url) == nil
    }

    /// URLSession that only follows hops ``shouldFollowRedirect(to:)`` allows.
    /// HTTP(S) is handled by ``SSRFPinnedURLProtocol``, which connects to the
    /// address ``pinEndpoint`` approved and keeps Host / TLS SNI on the original name.
    public static func urlSession(
        resourceTimeout: TimeInterval = 60,
        allowedHosts: Set<String>? = nil,
    ) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = resourceTimeout
        config.timeoutIntervalForRequest = resourceTimeout
        var headers: [AnyHashable: Any] = [
            SSRFPinnedURLProtocol.timeoutHeader: String(Int(resourceTimeout.rounded(.up))),
        ]
        if let allowedHosts, !allowedHosts.isEmpty {
            headers[SSRFPinnedURLProtocol.allowedHostsHeader] = allowedHosts.sorted().joined(separator: ",")
        }
        config.httpAdditionalHeaders = headers
        config.protocolClasses = [SSRFPinnedURLProtocol.self]
        return URLSession(
            configuration: config,
            delegate: SSRFRedirectGate.shared,
            delegateQueue: nil,
        )
    }

    /// Shared catalog/default fetch session (do not use URLSession.shared).
    public static let defaultSession: URLSession = urlSession()

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
            return String(bytes: buf.prefix(while: { $0 != 0 }).map(UInt8.init), encoding: .utf8)
        case AF_INET6:
            guard let addr = info.ai_addr else { return nil }
            var sin6 = sockaddr_in6()
            memcpy(&sin6, addr, MemoryLayout<sockaddr_in6>.size)
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var in6Addr = sin6.sin6_addr
            inet_ntop(AF_INET6, &in6Addr, &buf, socklen_t(INET6_ADDRSTRLEN))
            return String(bytes: buf.prefix(while: { $0 != 0 }).map(UInt8.init), encoding: .utf8)
        default:
            return nil
        }
    }
}

/// Connect to `connectIP` while HTTP Host and TLS SNI stay `originalHost`.
public struct PinnedEndpoint: Equatable, Sendable {
    public let originalHost: String
    public let connectIP: String
    public let port: Int
    public let usesTLS: Bool
}

public enum SSRFPinError: Error, Equatable, LocalizedError {
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case let .rejected(message): message
        }
    }
}

/// Refuses redirect hops that fail ``SSRFGuard.validate(url:)`` (private DNS, bad scheme).
final class SSRFRedirectGate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SSRFRedirectGate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        let allowed = SSRFPinnedURLProtocol.allowedHosts(in: request)
            ?? SSRFPinnedURLProtocol.allowedHosts(in: task.originalRequest)
        guard SSRFGuard.shouldFollowRedirect(to: url, allowedHosts: allowed) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
