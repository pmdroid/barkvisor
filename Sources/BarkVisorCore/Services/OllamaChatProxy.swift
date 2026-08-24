import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Buffered OpenAI-compatible chat proxy (PAS-269). Streaming is rejected so clients
/// do not get a JSON content-type over an SSE body.
public enum OllamaChatProxy {
    public static let jsonContentType = "application/json"

    private static let forwarded: Set<String> = [
        "content-type",
        "cache-control",
        "openai-model",
        "openai-processing-ms",
        "x-request-id",
    ]

    /// Model name from a chat body. Rejects `stream: true` because this proxy buffers.
    public static func parseBufferedRequest(_ body: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BarkVisorError.badRequest("Chat completion body must be JSON")
        }
        if isStreaming(object["stream"]) {
            throw BarkVisorError.badRequest("Streaming chat completions are not supported")
        }
        return try OllamaLocalProbe.modelName(fromObject: object)
    }

    public static func forwardedHeaders(_ upstream: [(String, String)]) -> [(String, String)] {
        var out: [(String, String)] = []
        var hasContentType = false
        for (name, value) in upstream {
            let key = name.lowercased()
            guard forwarded.contains(key) else { continue }
            if key == "content-type" { hasContentType = true }
            out.append((name, value))
        }
        if !hasContentType {
            out.append(("Content-Type", jsonContentType))
        }
        return out
    }

    public static func headers(from response: URLResponse) -> [(String, String)] {
        guard let http = response as? HTTPURLResponse else { return [] }
        var out: [(String, String)] = []
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String else { continue }
            out.append((name, String(describing: value)))
        }
        return out
    }

    private static func isStreaming(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? Int { return number != 0 }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return false
    }
}
