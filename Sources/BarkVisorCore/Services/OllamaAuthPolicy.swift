import Foundation

/// Path ACL for inference callers (PAS-269 keys, PAS-286 user role).
/// Admin session and full keys keep :7777. Inference fails closed.
public enum OllamaAuthPolicy {
    public enum Principal: String, Sendable, Equatable {
        case session
        case fullKey
        case inferenceKey
    }

    public static func principal(authMethod: String, apiKeyKind: String?) -> Principal {
        if authMethod == "apikey" {
            if apiKeyKind == APIKeyKind.inference.rawValue {
                return .inferenceKey
            }
            return .fullKey
        }
        return .session
    }

    /// Tokens inherit the user role. An admin inference token is still inference.
    public static func principal(
        userRole: String?,
        authMethod: String,
        apiKeyKind: String?,
    ) -> Principal {
        if UserRolePolicy.parseStored(userRole) == .inference {
            return .inferenceKey
        }
        return principal(authMethod: authMethod, apiKeyKind: apiKeyKind)
    }

    public static func allows(principal: Principal, method: String, path: String) -> Bool {
        switch principal {
        case .session, .fullKey:
            return true
        case .inferenceKey:
            return inferenceAllows(method: method.uppercased(), path: normalize(path))
        }
    }

    public static func inferenceAllows(method: String, path: String) -> Bool {
        let path = normalize(path)
        let method = method.uppercased()
        if isHomeMemberProxy(path) { return false }
        switch (method, path) {
        case ("GET", "/api/tags"),
             ("GET", "/api/ps"),
             ("GET", "/api/ollama/tags"),
             ("GET", "/api/ollama/ps"),
             ("GET", "/api/ollama/status"),
             ("GET", "/api/ollama/snapshot"),
             ("GET", "/api/home/ollama/models"),
             ("GET", "/api/home/ollama/status"),
             ("GET", "/v1/models"),
             ("GET", "/api/v1/models"),
             ("GET", "/api/auth/me"):
            return true
        case ("POST", "/v1/chat/completions"),
             ("POST", "/api/v1/chat/completions"),
             ("POST", "/api/ollama/v1/chat/completions"):
            return true
        default:
            return false
        }
    }

    public static func normalize(_ path: String) -> String {
        var value = path
        if let q = value.firstIndex(of: "?") {
            value = String(value[..<q])
        }
        if value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        if !value.hasPrefix("/") {
            value = "/" + value
        }
        return value
    }

    private static func isHomeMemberProxy(_ path: String) -> Bool {
        path.hasPrefix("/api/home/devices/")
    }
}
