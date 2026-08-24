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
    /// In-app Chat is retired. Completions stay on `/v1/chat/completions`;
    /// Chat/Agents are Library Onyx.
    static func visible(anyReachable _: Bool, modelCount _: Int) -> Bool {
        false
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
