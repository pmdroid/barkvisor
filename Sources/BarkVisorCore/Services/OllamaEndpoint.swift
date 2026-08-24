import Foundation

/// Loopback-only Ollama base URL. Host Ollama, not an arbitrary HTTP proxy.
public enum OllamaEndpoint {
    public static var defaultURL: URL {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = 11_434
        if let url = parts.url {
            return url
        }
        return URL(fileURLWithPath: "/unsupported-ollama-url")
    }

    public static func parse(_ raw: String?) throws -> URL {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultURL }
        guard let url = URL(string: trimmed), let host = url.host, let scheme = url.scheme else {
            throw BarkVisorError.badRequest("Ollama URL must be http://127.0.0.1:11434")
        }
        guard scheme.lowercased() == "http" else {
            throw BarkVisorError.badRequest("Ollama URL must use http on loopback")
        }
        let allowed = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard allowed else {
            throw BarkVisorError.badRequest("Ollama URL must be loopback (127.0.0.1)")
        }
        let port = url.port ?? 11_434
        guard (1 ... 65_535).contains(port) else {
            throw BarkVisorError.badRequest("Ollama port is invalid")
        }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host == "localhost" ? "127.0.0.1" : host
        parts.port = port
        guard let clean = parts.url else {
            throw BarkVisorError.badRequest("Ollama URL must be http://127.0.0.1:11434")
        }
        return clean
    }
}
