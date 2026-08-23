import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct OllamaHTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol OllamaHTTPTransport: Sendable {
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> OllamaHTTPResponse
    func stream(method: String, url: URL, headers: [String: String], body: Data?) -> AsyncThrowingStream<Data, Error>
}

/// Talks to host Ollama over native HTTP (PAS-269).
public struct OllamaClient: Sendable {
    public var baseURL: URL
    public var apiKey: String?
    public var transport: any OllamaHTTPTransport

    public init(
        baseURL: URL = OllamaEndpoint.defaultURL,
        apiKey: String? = nil,
        transport: any OllamaHTTPTransport = URLSessionOllamaTransport(),
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    public func tags() async throws -> [OllamaTagRecord] {
        let data = try await getJSON(path: "/api/tags")
        let decoded = try JSONDecoder().decode(TagsBody.self, from: data)
        return (decoded.models ?? []).map {
            OllamaTagRecord(
                name: $0.name ?? $0.model ?? "",
                digest: $0.digest,
                size: $0.size,
                parameterSize: $0.details?.parameterSize,
                quantization: $0.details?.quantizationLevel,
            )
        }.filter { !$0.name.isEmpty }
    }

    public func ps() async throws -> [OllamaRunningRecord] {
        let data = try await getJSON(path: "/api/ps")
        let decoded = try JSONDecoder().decode(PSBody.self, from: data)
        return (decoded.models ?? []).map {
            OllamaRunningRecord(
                name: $0.name ?? $0.model ?? "",
                digest: $0.digest,
                size: $0.size,
                sizeVRAM: $0.sizeVRAM,
            )
        }.filter { !$0.name.isEmpty }
    }

    public func pull(name: String) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        let model = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try? JSONSerialization.data(withJSONObject: ["name": model, "stream": true])
        let url = baseURL.appendingPathComponent("api/pull")
        let bytes = transport.stream(method: "POST", url: url, headers: headers(json: true), body: body)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var buffer = Data()
                    for try await chunk in bytes {
                        buffer.append(chunk)
                        while let range = buffer.range(of: Data([0x0A])) {
                            let line = buffer.subdata(in: buffer.startIndex ..< range.lowerBound)
                            buffer.removeSubrange(buffer.startIndex ... range.lowerBound)
                            if let event = decodePullEvent(line) {
                                if let error = event.error, !error.isEmpty {
                                    continuation.finish(throwing: BarkVisorError.badRequest(error))
                                    return
                                }
                                continuation.yield(event)
                            }
                        }
                    }
                    if !buffer.isEmpty, let event = decodePullEvent(buffer) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func load(model: String) async throws {
        _ = try await generate(model: model, keepAlive: "5m")
    }

    public func unload(model: String) async throws {
        _ = try await generate(model: model, keepAlive: 0)
    }

    public func chatCompletions(body: Data) async throws -> OllamaHTTPResponse {
        try await send(method: "POST", path: "/v1/chat/completions", body: body)
    }

    public func chatCompletionsStream(body: Data) -> AsyncThrowingStream<Data, Error> {
        guard let url = URL(string: "/v1/chat/completions", relativeTo: baseURL) else {
            return AsyncThrowingStream { $0.finish(throwing: BarkVisorError.badRequest("Invalid Ollama path")) }
        }
        return transport.stream(method: "POST", url: url, headers: headers(json: true), body: body)
    }

    public func versionReachable() async -> Bool {
        do {
            let response = try await send(method: "GET", path: "/api/version", body: nil)
            return (200 ..< 300).contains(response.status)
        } catch {
            return false
        }
    }

    private func generate(model: String, keepAlive: Any) async throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "prompt": "",
            "keep_alive": keepAlive,
            "stream": false,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await send(method: "POST", path: "/api/generate", body: body)
        try throwIfFailed(response)
        return response.body
    }

    private func getJSON(path: String) async throws -> Data {
        let response = try await send(method: "GET", path: path, body: nil)
        try throwIfFailed(response)
        return response.body
    }

    private func send(method: String, path: String, body: Data?) async throws -> OllamaHTTPResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw BarkVisorError.badRequest("Invalid Ollama path")
        }
        return try await transport.send(
            method: method,
            url: url,
            headers: headers(json: body != nil),
            body: body,
        )
    }

    private func headers(json: Bool) -> [String: String] {
        var headers: [String: String] = [:]
        if json {
            headers["Content-Type"] = "application/json"
        }
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    private func throwIfFailed(_ response: OllamaHTTPResponse) throws {
        guard (200 ..< 300).contains(response.status) else {
            let reason = String(data: response.body, encoding: .utf8) ?? "Ollama request failed"
            throw BarkVisorError.badGateway("Ollama: \(reason)")
        }
    }

    private func decodePullEvent(_ data: Data) -> OllamaPullEvent? {
        let trimmed = data.trimmingASCIINewlines
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(OllamaPullEvent.self, from: trimmed)
    }

    private struct TagsBody: Decodable {
        var models: [Model]?
        struct Model: Decodable {
            var name: String?
            var model: String?
            var size: Int64?
            var digest: String?
            var details: Details?
        }

        struct Details: Decodable {
            var parameterSize: String?
            var quantizationLevel: String?
            enum CodingKeys: String, CodingKey {
                case parameterSize = "parameter_size"
                case quantizationLevel = "quantization_level"
            }
        }
    }

    private struct PSBody: Decodable {
        var models: [Model]?
        struct Model: Decodable {
            var name: String?
            var model: String?
            var size: Int64?
            var digest: String?
            var sizeVRAM: Int64?
            enum CodingKeys: String, CodingKey {
                case name, model, size, digest
                case sizeVRAM = "size_vram"
            }
        }
    }
}

public struct URLSessionOllamaTransport: OllamaHTTPTransport {
    public init() {}

    public func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
    ) async throws -> OllamaHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return OllamaHTTPResponse(status: status, body: data)
    }

    public func stream(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: url, timeoutInterval: 3_600)
                    request.httpMethod = method
                    request.httpBody = body
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200 ..< 300).contains(status) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                        }
                        let reason = String(data: data, encoding: .utf8) ?? "Ollama pull failed"
                        throw BarkVisorError.badGateway("Ollama: \(reason)")
                    }
                    for try await line in bytes.lines {
                        if let data = (line + "\n").data(using: .utf8) {
                            continuation.yield(data)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

extension Data {
    fileprivate var trimmingASCIINewlines: Data {
        var start = startIndex
        var end = endIndex
        while start < end, self[start] == 0x0A || self[start] == 0x0D || self[start] == 0x20 {
            start += 1
        }
        while end > start, self[end - 1] == 0x0A || self[end - 1] == 0x0D || self[end - 1] == 0x20 {
            end -= 1
        }
        return subdata(in: start ..< end)
    }
}
