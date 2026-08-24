import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Ollama buffered chat proxy (PAS-269)")
struct OllamaChatProxyTests {
    @Test func `rejects streaming so the JSON content-type is not a lie`() throws {
        let err = #expect(throws: BarkVisorError.self) {
            _ = try OllamaChatProxy.parseBufferedRequest(
                Data(#"{"model":"llama3","stream":true,"messages":[]}"#.utf8),
            )
        }
        #expect(err?.errorDescription?.contains("Streaming") == true)
    }

    @Test func `accepts a buffered completion and keeps the model name`() throws {
        let model = try OllamaChatProxy.parseBufferedRequest(
            Data(#"{"model":"llama3","stream":false,"messages":[]}"#.utf8),
        )
        #expect(model == "llama3")
    }

    @Test func `forwards upstream content-type instead of forcing JSON`() {
        let headers = OllamaChatProxy.forwardedHeaders([
            ("X-Ignored", "nope"),
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Transfer-Encoding", "chunked"),
        ])
        #expect(headers.contains { $0.0 == "Content-Type" && $0.1 == "text/event-stream" })
        #expect(headers.contains { $0.0 == "Cache-Control" && $0.1 == "no-cache" })
        #expect(!headers.contains { $0.0 == "Transfer-Encoding" })
        #expect(!headers.contains { $0.0 == "X-Ignored" })
    }

    @Test func `defaults to JSON when upstream omitted content-type`() {
        let headers = OllamaChatProxy.forwardedHeaders([("X-Request-Id", "abc")])
        #expect(headers.contains { $0.0.lowercased() == "content-type" && $0.1 == "application/json" })
        #expect(headers.contains { $0.0 == "X-Request-Id" && $0.1 == "abc" })
    }
}
