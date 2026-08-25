import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Ollama library search")
struct OllamaLibrarySearchTests {
    @Test func `empty query returns no results`() {
        let models = [
            OllamaLibrarySearch.Model(name: "llama3.2"),
            OllamaLibrarySearch.Model(name: "mistral"),
        ]
        #expect(OllamaLibrarySearch.map(query: "", models: models).isEmpty)
        #expect(OllamaLibrarySearch.map(query: "  ", models: models).isEmpty)
    }

    @Test func `filters names case-insensitively`() {
        let models = [
            OllamaLibrarySearch.Model(name: "llama3.2", size: 2),
            OllamaLibrarySearch.Model(name: "Llama3:latest"),
            OllamaLibrarySearch.Model(name: "mistral"),
            OllamaLibrarySearch.Model(name: "phi3", description: "small llama cousin"),
        ]
        let hits = OllamaLibrarySearch.map(query: "LLAMA", models: models)
        #expect(hits.map(\.name) == ["llama3.2", "Llama3:latest", "phi3"])
        #expect(hits[0].size == 2)
        #expect(OllamaLibrarySearch.map(query: "xyz", models: models).isEmpty)
    }

    @Test func `skips blank and duplicate names`() {
        let models = [
            OllamaLibrarySearch.Model(name: "  "),
            OllamaLibrarySearch.Model(name: "gemma2"),
            OllamaLibrarySearch.Model(name: "Gemma2"),
        ]
        #expect(OllamaLibrarySearch.map(query: "gemma", models: models).map(\.name) == ["gemma2"])
    }

    @Test func `decodes popular tags list`() throws {
        let json = Data(
            """
            {"models":[{"name":"gemma4:31b","model":"gemma4:31b","size":12},{"model":"kimi-k2.6"},{"name":"  "}]}
            """.utf8,
        )
        let models = try OllamaLibrarySearch.models(from: json)
        #expect(models.map(\.name) == ["gemma4:31b", "kimi-k2.6"])
        #expect(models[0].size == 12)
        #expect(
            OllamaLibrarySearch.map(query: "gemma", models: models).map(\.name) == ["gemma4:31b"],
        )
    }

    @Test func `upstream is ollama.com tags`() throws {
        #expect(OllamaLibrarySearch.upstreamHost == "ollama.com")
        #expect(OllamaLibrarySearch.upstreamURLString == "https://ollama.com/api/tags")
        #expect(OllamaLibrarySearch.upstreamURL.absoluteString == OllamaLibrarySearch.upstreamURLString)
        #expect(OllamaLibrarySearch.allowedHosts == ["ollama.com"])
        #expect(
            SSRFGuard.fetchRejection(
                for: OllamaLibrarySearch.upstreamURL,
                allowedHosts: OllamaLibrarySearch.allowedHosts,
            ) == nil,
        )
        let other = try #require(URL(string: "https://example.com/api/tags"))
        #expect(SSRFGuard.fetchRejection(for: other, allowedHosts: OllamaLibrarySearch.allowedHosts) != nil)
        let loopback = try #require(URL(string: "https://127.0.0.1/api/tags"))
        #expect(SSRFGuard.fetchRejection(for: loopback, allowedHosts: OllamaLibrarySearch.allowedHosts) != nil)
        #expect(
            SSRFGuard.shouldFollowRedirect(
                to: OllamaLibrarySearch.upstreamURL,
                allowedHosts: OllamaLibrarySearch.allowedHosts,
            ),
        )
        #expect(!SSRFGuard.shouldFollowRedirect(to: other, allowedHosts: OllamaLibrarySearch.allowedHosts))
    }
}
