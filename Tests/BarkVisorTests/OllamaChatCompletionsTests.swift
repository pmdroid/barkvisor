import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Ollama chat completions (PAS-270)")
struct OllamaChatCompletionsTests {
    @Test func `stream true is the only streaming flag`() throws {
        let streaming = Data(#"{"model":"llama3","stream":true}"#.utf8)
        let off = Data(#"{"model":"llama3","stream":false}"#.utf8)
        let missing = Data(#"{"model":"llama3"}"#.utf8)
        let notJSON = Data("not-json".utf8)
        #expect(OllamaLocalProbe.wantsStream(fromChatBody: streaming))
        #expect(!OllamaLocalProbe.wantsStream(fromChatBody: off))
        #expect(!OllamaLocalProbe.wantsStream(fromChatBody: missing))
        #expect(!OllamaLocalProbe.wantsStream(fromChatBody: notJSON))
        #expect(try OllamaLocalProbe.modelName(fromChatBody: streaming) == "llama3")
    }

    @Test func `router still picks one Device when stream is true`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let probed = iso8601.string(from: now)
        let loc = OllamaModelLocation(
            hostId: "desk",
            displayName: "desk",
            running: true,
            reachable: true,
            probedAt: probed,
            size: 1_000,
            memoryTotalMB: 16_384,
            memoryUsedMB: 2_048,
            cpuLoadPercent: 4,
        )
        let catalog = OllamaHomeCatalog(
            anyReachable: true,
            anyInstalled: true,
            models: [
                OllamaCatalogModel(name: "llama3:latest", running: true, locations: [loc]),
            ],
        )
        #expect(OllamaRouter.pick(model: "llama3", catalog: catalog, now: now)?.hostId == "desk")
        #expect(OllamaRouter.pick(model: "missing", catalog: catalog, now: now) == nil)
    }

    @Test func `stream completions use the byte stream transport`() async throws {
        let transport = RecordingChatTransport()
        transport.chunks = [
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n".utf8),
            Data("data: [DONE]\n".utf8),
        ]
        let client = try OllamaClient(
            baseURL: #require(URL(string: "http://127.0.0.1:11434")),
            transport: transport,
        )
        let body = Data(#"{"model":"llama3","stream":true,"messages":[]}"#.utf8)
        var collected = Data()
        for try await chunk in client.chatCompletionsStream(body: body) {
            collected.append(chunk)
        }
        #expect(transport.streamCalls == 1)
        #expect(transport.sendCalls == 0)
        #expect(String(data: collected, encoding: .utf8)?.contains("Hi") == true)
        #expect(transport.lastURL?.path.hasSuffix("/v1/chat/completions") == true)
    }

    @Test func `non-stream completions collect a JSON body`() async throws {
        let transport = RecordingChatTransport()
        transport.response = OllamaHTTPResponse(
            status: 200,
            body: Data(#"{"choices":[{"message":{"content":"done"}}]}"#.utf8),
        )
        let client = try OllamaClient(
            baseURL: #require(URL(string: "http://127.0.0.1:11434")),
            transport: transport,
        )
        let body = Data(#"{"model":"llama3","stream":false,"messages":[]}"#.utf8)
        let response = try await client.chatCompletions(body: body)
        #expect(transport.sendCalls == 1)
        #expect(transport.streamCalls == 0)
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8)?.contains("done") == true)
    }

    @Test func `sse proxy throws before HTTP 200 when the first chunk fails`() async {
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            continuation.finish(throwing: BarkVisorError.badGateway("Ollama: down"))
        }
        await #expect(throws: BarkVisorError.self) {
            _ = try await OllamaChatProxy.stream(chunks)
        }
    }

    @Test func `member stream default fails closed on a non-2xx hop`() async throws {
        let client = StatusProxyClient(status: 502, body: Data(#"{"error":"down"}"#.utf8))
        let url = try #require(URL(string: "https://10.0.0.8:7778/api/ollama/v1/chat/completions"))
        let stream = client.stream(HomeDeviceProxyRequest(method: "POST", url: url, body: Data()))
        await #expect(throws: BarkVisorError.self) {
            for try await _ in stream {}
        }
    }
}

private struct StatusProxyClient: HomeDeviceProxyClient {
    var status: Int
    var body: Data

    func send(_: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        HomeDeviceProxyResponse(status: status, body: body)
    }
}

private final class RecordingChatTransport: OllamaHTTPTransport, @unchecked Sendable {
    var streamCalls = 0
    var sendCalls = 0
    var chunks: [Data] = []
    var response = OllamaHTTPResponse(status: 200, body: Data())
    var lastURL: URL?

    func send(method _: String, url: URL, headers _: [String: String], body _: Data?) async throws
        -> OllamaHTTPResponse {
        sendCalls += 1
        lastURL = url
        return response
    }

    func stream(method _: String, url: URL, headers _: [String: String], body _: Data?)
        -> AsyncThrowingStream<Data, Error> {
        streamCalls += 1
        lastURL = url
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
