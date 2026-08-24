import Foundation
import Testing
@testable import BarkVisorConsole

struct InferenceHowToMintTests {
    @Test func `mints inference key when session has none`() {
        let body = InferenceHowToMint.createBody()
        #expect(body.kind == "inference")
        #expect(body.name == "Ollama howto (auto)")
        #expect(body.expiresIn == APIKeyDisplay.defaultExpiry)
        #expect(InferenceHowToMint.needsMint(keys: []))
        #expect(InferenceHowToMint.needsMint(keys: [key(kind: "full")]))
        #expect(!InferenceHowToMint.needsMint(keys: [key(kind: "inference")]))
        #expect(!InferenceHowToMint.needsMint(keys: [key(kind: "full"), key(kind: "inference")]))
        let now = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        #expect(
            InferenceHowToMint.needsMint(
                keys: [key(kind: "inference", expiresAt: "2026-01-01T00:00:00Z")],
                now: now,
            ),
        )
        #expect(
            !InferenceHowToMint.needsMint(
                keys: [key(kind: "inference", expiresAt: "2026-12-01T00:00:00Z")],
                now: now,
            ),
        )
    }

    @Test func `inference role still requests inference kind`() {
        #expect(InferenceHowToMint.createBody().kind == APIKeyKindOption.inference.rawValue)
        #expect(APIKeyKindOption.createDefault == .inference)
    }

    @Test func `auth failure banners sign in not a role 403 path`() {
        #expect(
            InferenceHowToMint.bannerMessage(from: APIError.unauthorized) == APIKeyDisplay.signInRequired,
        )
        #expect(
            InferenceHowToMint.bannerMessage(from: APIError.http(status: 401, reason: "expired"))
                == APIKeyDisplay.signInRequired,
        )
        #expect(
            InferenceHowToMint.bannerMessage(from: APIError.http(status: 403, reason: "forbidden"))
                == "forbidden",
        )
        #expect(
            InferenceHowToMint.bannerMessage(from: APIError.http(status: 403, reason: "forbidden"))
                != APIKeyDisplay.forbiddenFallback,
        )
        #expect(APIKeyDisplay.forbiddenMessage(from: APIError.unauthorized) == nil)
    }

    private func key(kind: String, expiresAt: String? = nil) -> APIKeyResponse {
        APIKeyResponse(
            id: "k-\(kind)",
            name: kind,
            keyPrefix: "barkvisor_",
            expiresAt: expiresAt,
            lastUsedAt: nil,
            createdAt: "2026-01-01T00:00:00Z",
            kind: kind,
        )
    }
}
