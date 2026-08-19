import Foundation

/// Phone sign-in URI (PAS-242). Distinct from pairing (`barkvisor://pair/v1`).
///
/// Encodes as `barkvisor://login/v1?code=…&host=…&port=…`.
public struct LoginPayload: Sendable, Equatable {
    public static let scheme = "barkvisor"
    public static let hostName = "login"
    public static let path = "/v1"

    public var code: String
    public var host: String
    public var port: Int

    public init(code: String, host: String, port: Int) {
        self.code = PairingCode.display(code)
        self.host = host
        self.port = port
    }

    public var uri: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.hostName
        components.path = Self.path
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
        ]
        return components.string ?? "\(Self.scheme)://\(Self.hostName)\(Self.path)"
    }

    public static func parse(_ raw: String) throws -> LoginPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            throw BarkVisorError.badRequest("Not a sign-in URI")
        }
        guard components.scheme == scheme else {
            throw BarkVisorError.badRequest("Sign-in URI must use \(scheme)://")
        }
        guard components.host == hostName else {
            if components.host == PairingPayload.hostName {
                throw BarkVisorError.badRequest(
                    "That QR pairs Devices. Scan a sign-in QR from Settings on the Device.",
                )
            }
            throw BarkVisorError.badRequest("Sign-in URI host must be \(hostName)")
        }
        let path = components.path.isEmpty ? Self.path : components.path
        guard path == Self.path || path == "\(Self.path)/" else {
            throw BarkVisorError.badRequest("Unsupported sign-in URI version")
        }
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { first, _ in first },
        )
        guard let code = query["code"], PairingCode.isValid(code) else {
            throw BarkVisorError.badRequest("Sign-in URI is missing a valid code")
        }
        guard let hostRaw = query["host"], let host = PairingPayload.sanitizeHost(hostRaw) else {
            throw BarkVisorError.badRequest("Sign-in URI has an invalid host")
        }
        guard let portRaw = query["port"], let port = Int(portRaw), (1 ... 65_535).contains(port) else {
            throw BarkVisorError.badRequest("Sign-in URI has an invalid port")
        }
        return LoginPayload(code: code, host: host, port: port)
    }
}
