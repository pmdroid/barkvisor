import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Phone sign-in URI. Distinct from pairing (`barkvisor://pair/v1`).
enum LoginURI {
    static let scheme = "barkvisor"
    static let hostName = "login"
    static let path = "/v1"
    static let pairingHost = "pair"

    struct Payload: Equatable {
        var code: String
        var host: String
        var port: Int

        var deviceURL: String {
            let wrapped = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return "http://\(wrapped):\(port)"
        }
    }

    static func parse(_ raw: String) throws -> Payload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            throw APIError.http(status: 400, reason: "Not a sign-in QR")
        }
        guard components.scheme == scheme else {
            throw APIError.http(status: 400, reason: "Not a sign-in QR")
        }
        if components.host == pairingHost {
            throw APIError.http(
                status: 400,
                reason: "That QR pairs Devices. Scan a sign-in QR from Settings on the Device.",
            )
        }
        guard components.host == hostName else {
            throw APIError.http(status: 400, reason: "Not a sign-in QR")
        }
        let path = components.path.isEmpty ? Self.path : components.path
        guard path == Self.path || path == "\(Self.path)/" else {
            throw APIError.http(status: 400, reason: "Unsupported sign-in QR")
        }
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { first, _ in first },
        )
        guard let code = query["code"], !code.isEmpty else {
            throw APIError.http(status: 400, reason: "Sign-in QR is missing a code")
        }
        guard let hostRaw = query["host"], let host = sanitizeHost(hostRaw) else {
            throw APIError.http(status: 400, reason: "Sign-in QR has an invalid host")
        }
        guard let portRaw = query["port"], let port = Int(portRaw), (1 ... 65_535).contains(port) else {
            throw APIError.http(status: 400, reason: "Sign-in QR has an invalid port")
        }
        return Payload(code: code, host: host, port: port)
    }

    /// Same advertised-host allow-list as `PairingPayload.sanitizeHost`.
    static func isAllowedHost(_ raw: String) -> Bool {
        sanitizeHost(raw) != nil
    }

    static func sanitizeHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
        if trimmed.contains(where: { $0 == "/" || $0 == "@" || $0 == "\\" || $0.isWhitespace }) {
            return nil
        }
        if trimmed.contains("://") { return nil }
        if isBlockedJoinHost(trimmed) { return nil }
        return trimmed
    }

    private static func isBlockedJoinHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host.hasPrefix("localhost.") { return true }
        if host == "metadata" || host == "metadata.google.internal" { return true }
        if host.hasSuffix(".internal") { return true }
        if let octets = parseIPv4Octets(host) {
            return !isAllowedJoinIPv4(octets)
        }
        if let addr = parseIPv6(host) {
            return isBlockedJoinIPv6(addr)
        }
        return false
    }

    private static func isAllowedJoinIPv4(_ parts: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        if parts == (100, 100, 100, 200) { return false }
        if parts.0 == 10 { return true }
        if parts.0 == 172, (16 ... 31).contains(parts.1) { return true }
        if parts.0 == 192, parts.1 == 168 { return true }
        if parts.0 == 100, (64 ... 127).contains(parts.1) { return true }
        return false
    }

    private static func isBlockedJoinIPv6(_ addr: in6_addr) -> Bool {
        withUnsafeBytes(of: addr) { raw in
            let bytes = Array(raw)
            guard bytes.count == 16 else { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return !isAllowedJoinIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            let isULA = (bytes[0] & 0xFE) == 0xFC
            if isULA {
                if bytes[0] == 0xFD, bytes[1] == 0x00, bytes[2] == 0x0E, bytes[3] == 0xC2 {
                    return true
                }
                return false
            }
            return true
        }
    }

    private static func parseIPv4Octets(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var addr = in_addr()
        guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        let canonical = String(cString: buf)
        let parts = canonical.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0], parts[1], parts[2], parts[3])
    }

    private static func parseIPv6(_ host: String) -> in6_addr? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return addr
    }
}

/// Camera setup failures for the sign-in QR scanner. Connect/Login must show a banner.
enum LoginQRScanError: String, Equatable {
    case cameraDenied = "Camera access is required to scan a sign-in QR"
    case cameraUnavailable = "Camera is not available to scan a sign-in QR"

    static func failure(authorized: Bool, cameraPresent: Bool) -> LoginQRScanError? {
        if !authorized { return .cameraDenied }
        if !cameraPresent { return .cameraUnavailable }
        return nil
    }
}
