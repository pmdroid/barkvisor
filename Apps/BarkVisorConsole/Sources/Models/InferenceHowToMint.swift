import Foundation

/// Auto-mint an inference key when the Ollama howto card opens (GitHub #225).
enum InferenceHowToMint {
    static let autoName = "Ollama howto (auto)"
    static let kind = APIKeyKindOption.inference.rawValue
    static let expiresIn = APIKeyDisplay.defaultExpiry

    static func needsMint(keys: [APIKeyResponse], now: Date = Date()) -> Bool {
        !keys.contains { $0.kind == kind && !isExpired($0.expiresAt, now: now) }
    }

    static func isExpired(_ expiresAt: String?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        guard let date = APIKeyDisplay.parseISO8601(expiresAt) else { return false }
        return date < now
    }

    static func createBody() -> APIKeyCreateBody {
        APIKeyCreateBody(name: autoName, expiresIn: expiresIn, kind: kind)
    }

    /// Session/auth failure copy. 403 is not treated as "not admin".
    static func bannerMessage(from error: Error) -> String {
        guard let api = error as? APIError else {
            return error.localizedDescription
        }
        switch api {
        case .unauthorized:
            return APIKeyDisplay.signInRequired
        case let .http(status, _) where status == 401:
            return APIKeyDisplay.signInRequired
        default:
            return api.localizedDescription
        }
    }
}
