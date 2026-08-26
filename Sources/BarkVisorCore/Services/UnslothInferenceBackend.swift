import Foundation

public final class UnslothInferenceBackend: InferenceBackend, @unchecked Sendable {
    public static let host = "127.0.0.1"
    public static let port = 18_888

    public static var defaultBaseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    public let modelsDir: URL
    public let baseURL: URL
    public let readyTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let detect: @Sendable () -> OllamaDetectResult
    private let spawner: any UnslothProcessSpawner
    private let transport: any OllamaHTTPTransport

    private let lock = NSLock()
    private var child: (any UnslothChildProcess)?
    private var servingModel: String?
    private var sessionKey: String?

    public init(
        modelsDir: URL,
        baseURL: URL = UnslothInferenceBackend.defaultBaseURL,
        readyTimeout: TimeInterval = 60,
        pollInterval: TimeInterval = 0.25,
        detect: @escaping @Sendable () -> OllamaDetectResult = { UnslothDetect.liveDetect() },
        spawner: any UnslothProcessSpawner = FoundationUnslothSpawner(),
        transport: any OllamaHTTPTransport = URLSessionOllamaTransport(),
    ) {
        self.modelsDir = modelsDir
        self.baseURL = baseURL
        self.readyTimeout = readyTimeout
        self.pollInterval = pollInterval
        self.detect = detect
        self.spawner = spawner
        self.transport = transport
    }

    public var backendId: String {
        "unsloth"
    }

    public func catalog() async throws -> [OllamaLocalModel] {
        try UnslothStagedModels.models(in: modelsDir, running: currentModel())
    }

    public func pull(name _: String) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: BarkVisorError.badRequest(
                    "Unsloth pull is unsupported. Stage model weights under \(modelsDir.path)",
                ),
            )
        }
    }

    public func start(model: String) async throws {
        let detected = detect()
        guard detected.installed, let binaryPath = detected.binaryPath else {
            throw BarkVisorError.processSpawnFailed(
                "Unsloth is not installed on this Device. \(UnslothDetect.installHint)",
            )
        }
        let staged = try UnslothStagedModels.entries(in: modelsDir)
        guard let entry = staged.first(where: { OllamaModelName.matches(model, available: $0.name) })
        else {
            throw BarkVisorError.badRequest(
                "Model \(model) is not staged under \(modelsDir.path)",
            )
        }
        if isServing(model: model) { return }
        await shutdown()
        let apiKey = Self.randomAPIKey()
        let spawned = try spawner.spawn(
            executablePath: binaryPath,
            arguments: [
                "run",
                "--model", entry.path.path,
                "-H", Self.host,
                "-p", String(Self.port),
                "--disable-tools",
                "--api-key", apiKey,
            ],
        )
        do {
            try await waitUntilReady(apiKey: apiKey)
        } catch {
            await shutdown(spawned)
            throw error
        }
        lock.withLock {
            child = spawned
            servingModel = entry.name
            sessionKey = apiKey
        }
    }

    public func stop(model _: String) async throws {
        await shutdown()
    }

    public func chatCompletions(body: Data) async throws -> OllamaHTTPResponse {
        let client = try OllamaClient(baseURL: baseURL, apiKey: requireSessionKey(), transport: transport)
        return try await client.chatCompletions(body: body)
    }

    public func chatCompletionsStream(body: Data) -> AsyncThrowingStream<Data, Error> {
        guard let key = currentSessionKey() else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: BarkVisorError.badGateway(Self.notRunningMessage))
            }
        }
        return OllamaClient(baseURL: baseURL, apiKey: key, transport: transport)
            .chatCompletionsStream(body: body)
    }

    public func isReachable() async -> Bool {
        detect().installed
    }

    public func snapshot(
        hostId: String,
        displayName: String?,
        detectResult: OllamaDetectResult,
        memoryTotalMB: Int?,
        memoryUsedMB: Int?,
        cpuLoadPercent: Double?,
        now: Date = Date(),
    ) async -> OllamaDeviceSnapshot {
        let reachable = await Self.serverUp(transport: transport, baseURL: baseURL, apiKey: currentSessionKey())
        let models = (try? UnslothStagedModels.models(in: modelsDir, running: currentModel())) ?? []
        return OllamaDeviceSnapshot(
            hostId: hostId,
            displayName: displayName,
            installed: detectResult.installed,
            reachable: reachable,
            binaryPath: detectResult.binaryPath,
            installHint: detectResult.installHint,
            probedAt: iso8601.string(from: now),
            models: models,
            memoryTotalMB: memoryTotalMB,
            memoryUsedMB: memoryUsedMB,
            cpuLoadPercent: cpuLoadPercent,
            backend: backendId,
        )
    }

    public static func serverUp(
        transport: any OllamaHTTPTransport,
        baseURL: URL,
        apiKey: String? = nil,
    ) async -> Bool {
        guard let url = URL(string: "/v1/models", relativeTo: baseURL) else { return false }
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        guard let response = try? await transport.send(method: "GET", url: url, headers: headers, body: nil)
        else {
            return false
        }
        return (200 ..< 300).contains(response.status)
    }

    public static func randomAPIKey() -> String {
        var seed = SystemRandomNumberGenerator()
        let bytes = (0 ..< 24).map { _ in UInt8.random(in: .min ... .max, using: &seed) }
        return Data(bytes).base64EncodedString()
    }

    static var notRunningMessage: String {
        "Unsloth server is not running on this Device. Start a model first."
    }

    private func waitUntilReady(apiKey: String) async throws {
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if await Self.serverUp(transport: transport, baseURL: baseURL, apiKey: apiKey) { return }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw BarkVisorError.timeout(
            "Unsloth did not serve \(baseURL.absoluteString)/v1/models within \(Int(readyTimeout))s",
        )
    }

    private func isServing(model: String) -> Bool {
        lock.withLock {
            guard child != nil, let serving = servingModel else { return false }
            return OllamaModelName.matches(model, available: serving)
        }
    }

    private func shutdown(_ target: (any UnslothChildProcess)? = nil) async {
        let current: (any UnslothChildProcess)? = lock.withLock {
            let existing = target ?? child
            if target == nil {
                child = nil
                servingModel = nil
                sessionKey = nil
            }
            return existing
        }
        guard let current else { return }
        current.terminate()
        await current.killAfterGrace(3)
    }

    private func requireSessionKey() throws -> String {
        try lock.withLock {
            guard child != nil, let key = sessionKey else {
                throw BarkVisorError.badGateway(Self.notRunningMessage)
            }
            return key
        }
    }

    private func currentSessionKey() -> String? {
        lock.withLock {
            guard child != nil else { return nil }
            return sessionKey
        }
    }

    private func currentModel() -> String? {
        lock.withLock {
            guard child != nil else { return nil }
            return servingModel
        }
    }
}
