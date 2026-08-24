import Foundation

/// Auto-mint an inference key when the Ollama howto card opens (GitHub #225).
enum InferenceHowToMint {
    static let autoName = "Ollama howto (auto)"
    static let kind = APIKeyKindOption.inference.rawValue
    static let expiresIn = APIKeyDisplay.defaultExpiry

    static func needsMint(keys: [APIKeyResponse]) -> Bool {
        !keys.contains { $0.kind == kind }
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
