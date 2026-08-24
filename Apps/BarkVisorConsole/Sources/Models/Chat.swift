import Foundation

struct ChatTurn: Identifiable, Hashable {
    var id = UUID()
    var role: String
    var content: String

    var isUser: Bool {
        role == "user"
    }
}

struct ChatCompletionBody: Encodable {
    var model: String
    var stream: Bool
    var messages: [ChatWireMessage]
}

struct ChatWireMessage: Encodable, Equatable {
    var role: String
    var content: String
}

enum ChatStreamApply {
    /// Bind a delta to the originating assistant turn and send generation.
    /// Stop/Send bump `currentGeneration` so a cancelled stream cannot write
    /// onto a newer placeholder.
    static func append(
        delta: String,
        to turns: inout [ChatTurn],
        assistantID: UUID,
        generation: Int,
        currentGeneration: Int,
    ) {
        guard generation == currentGeneration, !delta.isEmpty else { return }
        guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
        turns[index].content += delta
    }

    /// Drop only this send's empty assistant (and its user prompt) on failure.
    static func rollbackFailedSend(
        turns: inout [ChatTurn],
        draft: inout String,
        originalText: String,
        assistantID: UUID,
        generation: Int,
        currentGeneration: Int,
    ) {
        guard generation == currentGeneration else { return }
        guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
        guard turns[index].content.isEmpty else { return }
        if index > 0, turns[index - 1].isUser {
            draft = originalText
            turns.removeSubrange((index - 1) ... index)
        } else {
            turns.remove(at: index)
        }
    }
}

enum ChatAvailability {
    static func visible(anyReachable: Bool, modelCount: Int) -> Bool {
        anyReachable && modelCount > 0
    }

    static func visible(catalog: OllamaHomeCatalog?) -> Bool {
        guard let catalog else { return false }
        return visible(anyReachable: catalog.anyReachable, modelCount: catalog.models.count)
    }

    static func defaultModel(in catalog: OllamaHomeCatalog?) -> String {
        guard let catalog else { return "" }
        if let running = catalog.models.first(where: { $0.running }) {
            return running.name
        }
        return catalog.models.first?.name ?? ""
    }
}

enum ChatSSE {
    static func content(fromLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first
        else { return nil }
        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            return content
        }
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content
        }
        return nil
    }

    static func drain(buffer: inout String) -> [String] {
        var deltas: [String] = []
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            if let content = content(fromLine: line) {
                deltas.append(content)
            }
        }
        return deltas
    }
}

/// iOS Chat tab loads the Home web Chat route in WKWebView (GitHub #228).
/// Auth is the session JWT or minted inference key, injected as a header,
/// cookie, and `localStorage` — never the page query string.
enum ChatWebSession {
    static let routePath = "/chat"
    static let tokenStorageKey = "token"
    static let tokenCookieName = "token"
    static let authorizationHeaderName = "Authorization"

    static func pageURL(home origin: URL) throws -> URL {
        let origin = try DeviceURL.normalize(origin.absoluteString)
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.path = routePath
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    static func authorizationHeader(token: String) -> String {
        "Bearer \(token)"
    }

    static func pageRequest(home origin: URL, token: String) throws -> URLRequest {
        let url = try pageURL(home: origin)
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(token: token), forHTTPHeaderField: authorizationHeaderName)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        return request
    }

    static func cookie(home origin: URL, token: String) -> HTTPCookie? {
        let origin = (try? DeviceURL.normalize(origin.absoluteString)) ?? origin
        var properties: [HTTPCookiePropertyKey: Any] = [
            .originURL: origin,
            .path: "/",
            .name: tokenCookieName,
            .value: token,
        ]
        if origin.scheme?.lowercased() == "https" {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }

    static func userScriptSource(token: String) -> String {
        let tokenJSON = jsonString(token)
        let keyJSON = jsonString(tokenStorageKey)
        let cookieNameJSON = jsonString(tokenCookieName)
        return """
        (function() {
          var token = \(tokenJSON);
          try { localStorage.setItem(\(keyJSON), token); } catch (e) {}
          try {
            document.cookie = \(cookieNameJSON) + '=' + encodeURIComponent(token) + '; path=/; SameSite=Lax';
          } catch (e) {}
        })();
        """
    }

    static func isHomeOrigin(_ url: URL, home origin: URL) -> Bool {
        let home = (try? DeviceURL.normalize(origin.absoluteString)) ?? origin
        return DeviceURL.sameOrigin(url, home)
    }

    static func containsSecret(_ url: URL, secret: String) -> Bool {
        StreamURL.containsSecret(url, secret: secret)
    }

    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return encoded
    }
}
