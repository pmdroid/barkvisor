import Testing
@testable import BarkVisorCore

@Suite("Ollama proxy auth (PAS-269)")
struct OllamaAuthPolicyTests {
    @Test func `session and full keys keep the rest of the API`() {
        #expect(OllamaAuthPolicy.allows(principal: .session, method: "GET", path: "/api/vms"))
        #expect(OllamaAuthPolicy.allows(principal: .fullKey, method: "POST", path: "/api/ollama/pull"))
        #expect(OllamaAuthPolicy.allows(principal: .fullKey, method: "PUT", path: "/api/ollama/settings"))
    }

    @Test func `inference can list and complete but not pull keys or member proxy`() {
        #expect(
            OllamaAuthPolicy.allows(
                principal: .inferenceKey, method: "GET", path: "/api/home/ollama/models",
            ),
        )
        #expect(
            OllamaAuthPolicy.allows(principal: .inferenceKey, method: "GET", path: "/api/tags"),
        )
        #expect(
            OllamaAuthPolicy.allows(principal: .inferenceKey, method: "GET", path: "/api/ps"),
        )
        #expect(
            OllamaAuthPolicy.allows(
                principal: .inferenceKey, method: "GET", path: "/api/ollama/snapshot",
            ),
        )
        #expect(
            OllamaAuthPolicy.allows(
                principal: .inferenceKey, method: "POST", path: "/v1/chat/completions",
            ),
        )
        #expect(
            OllamaAuthPolicy.allows(
                principal: .inferenceKey, method: "POST", path: "/api/v1/chat/completions",
            ),
        )
        #expect(
            !OllamaAuthPolicy.allows(principal: .inferenceKey, method: "POST", path: "/api/ollama/pull"),
        )
        #expect(
            !OllamaAuthPolicy.allows(principal: .inferenceKey, method: "GET", path: "/api/ollama/settings"),
        )
        #expect(
            !OllamaAuthPolicy.allows(principal: .inferenceKey, method: "GET", path: "/api/vms"),
        )
        #expect(
            !OllamaAuthPolicy.allows(
                principal: .inferenceKey,
                method: "GET",
                path: "/api/home/devices/abc/v1/ollama/tags",
            ),
        )
    }

    @Test func `principal maps inference kind from API key`() {
        #expect(
            OllamaAuthPolicy.principal(authMethod: "apikey", apiKeyKind: "inference") == .inferenceKey,
        )
        #expect(OllamaAuthPolicy.principal(authMethod: "apikey", apiKeyKind: "full") == .fullKey)
        #expect(OllamaAuthPolicy.principal(authMethod: "jwt", apiKeyKind: nil) == .session)
    }

    @Test func `inference user role is inference even with a full key or JWT`() {
        #expect(
            OllamaAuthPolicy.principal(
                userRole: "inference", authMethod: "jwt", apiKeyKind: nil,
            ) == .inferenceKey,
        )
        #expect(
            OllamaAuthPolicy.principal(
                userRole: "inference", authMethod: "apikey", apiKeyKind: "full",
            ) == .inferenceKey,
        )
        #expect(
            OllamaAuthPolicy.principal(
                userRole: "admin", authMethod: "apikey", apiKeyKind: "inference",
            ) == .inferenceKey,
        )
        #expect(
            OllamaAuthPolicy.principal(
                userRole: "admin", authMethod: "jwt", apiKeyKind: nil,
            ) == .session,
        )
        #expect(
            OllamaAuthPolicy.principal(
                userRole: "nope", authMethod: "jwt", apiKeyKind: nil,
            ) == .inferenceKey,
        )
    }

    @Test func `inference cannot pull keys or attach USB`() {
        #expect(
            !OllamaAuthPolicy.allows(
                principal: .inferenceKey, method: "POST", path: "/api/auth/keys",
            ),
        )
        #expect(
            !OllamaAuthPolicy.allows(
                principal: .inferenceKey, method: "POST", path: "/api/vms/vm-1/usb",
            ),
        )
        #expect(
            !OllamaAuthPolicy.allows(
                principal: .inferenceKey, method: "POST", path: "/api/vms/vm-1/gpu",
            ),
        )
        #expect(
            OllamaAuthPolicy.allows(
                principal: .inferenceKey, method: "GET", path: "/api/auth/me",
            ),
        )
    }
}
