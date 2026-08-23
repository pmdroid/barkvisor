import Foundation

struct OllamaHomeCatalog: Decodable, Hashable {
    var anyReachable: Bool
    var anyInstalled: Bool
    var models: [OllamaCatalogModel]
    var devices: [OllamaDeviceStatus]
}

struct OllamaCatalogModel: Decodable, Hashable, Identifiable {
    var name: String
    var running: Bool
    var locations: [OllamaModelLocation]

    var id: String {
        name
    }
}

struct OllamaModelLocation: Decodable, Hashable {
    var hostId: String
    var displayName: String?
    var running: Bool
    var reachable: Bool
    var probedAt: String
}

struct OllamaDeviceStatus: Decodable, Hashable {
    var hostId: String
    var displayName: String?
    var installed: Bool
    var reachable: Bool
    var stale: Bool
    var installHint: String
}

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
