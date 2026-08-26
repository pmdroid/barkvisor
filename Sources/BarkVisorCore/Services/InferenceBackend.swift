import Foundation

public protocol InferenceBackend: Sendable {
    var backendId: String { get }

    func catalog() async throws -> [OllamaLocalModel]

    func pull(name: String) -> AsyncThrowingStream<OllamaPullEvent, Error>

    func start(model: String) async throws

    func stop(model: String) async throws

    func chatCompletions(body: Data) async throws -> OllamaHTTPResponse

    func chatCompletionsStream(body: Data) -> AsyncThrowingStream<Data, Error>

    func isReachable() async -> Bool
}

public struct OllamaInferenceBackend: InferenceBackend {
    public let client: OllamaClient

    public init(client: OllamaClient) {
        self.client = client
    }

    public var backendId: String {
        "ollama"
    }

    public func catalog() async throws -> [OllamaLocalModel] {
        let tags = try await client.tags()
        let running = try await client.ps()
        return OllamaCatalog.merge(tags: tags, running: running)
    }

    public func pull(name: String) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        client.pull(name: name)
    }

    public func start(model: String) async throws {
        try await client.load(model: model)
    }

    public func stop(model: String) async throws {
        try await client.unload(model: model)
    }

    public func chatCompletions(body: Data) async throws -> OllamaHTTPResponse {
        try await client.chatCompletions(body: body)
    }

    public func chatCompletionsStream(body: Data) -> AsyncThrowingStream<Data, Error> {
        client.chatCompletionsStream(body: body)
    }

    public func isReachable() async -> Bool {
        await client.versionReachable()
    }
}
