import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Ollama load fit check (PAS-269)")
struct OllamaFitTests {
    @Test func `unknown size is allowed`() {
        #expect(OllamaFit.check(modelBytes: nil, memoryTotalMB: 8_192, memoryUsedMB: 1_024).ok)
    }

    @Test func `fits when free memory covers model plus overhead`() {
        let result = OllamaFit.check(
            modelBytes: 1_024 * 1_024 * 1_000,
            memoryTotalMB: 8_192,
            memoryUsedMB: 1_024,
        )
        #expect(result.ok)
    }

    @Test func `rejects when this Device is too tight`() {
        let result = OllamaFit.check(
            modelBytes: 1_024 * 1_024 * 8_000,
            memoryTotalMB: 4_096,
            memoryUsedMB: 3_000,
        )
        #expect(!result.ok)
        #expect(result.reason?.contains("Ollama") == true)
        #expect(result.reason?.contains("Device") == true)
    }

    @Test func `loopback endpoint only`() throws {
        let url = try OllamaEndpoint.parse("http://127.0.0.1:11434")
        #expect(url.host == "127.0.0.1")
        #expect(throws: BarkVisorError.self) {
            _ = try OllamaEndpoint.parse("http://192.168.1.9:11434")
        }
        #expect(throws: BarkVisorError.self) {
            _ = try OllamaEndpoint.parse("https://127.0.0.1:11434")
        }
    }

    @Test func `chat body requires model`() throws {
        let name = try OllamaLocalProbe.modelName(
            fromChatBody: Data(#"{"model":"llama3","messages":[]}"#.utf8),
        )
        #expect(name == "llama3")
        #expect(throws: BarkVisorError.self) {
            _ = try OllamaLocalProbe.modelName(fromChatBody: Data(#"{"messages":[]}"#.utf8))
        }
    }
}
