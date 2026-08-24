import Foundation

/// Build a Device snapshot from detect + native Ollama HTTP (PAS-269).
public enum OllamaLocalProbe {
    public static func snapshot(
        hostId: String,
        displayName: String?,
        detect: OllamaDetectResult,
        client: OllamaClient,
        memoryTotalMB: Int?,
        memoryUsedMB: Int?,
        cpuLoadPercent: Double?,
        now: Date = Date(),
    ) async -> OllamaDeviceSnapshot {
        let reachable = await client.versionReachable()
        var models: [OllamaLocalModel] = []
        if reachable {
            let tags = await (try? client.tags()) ?? []
            let running = await (try? client.ps()) ?? []
            models = OllamaCatalog.merge(tags: tags, running: running)
        }
        return OllamaDeviceSnapshot(
            hostId: hostId,
            displayName: displayName,
            installed: detect.installed,
            reachable: reachable,
            binaryPath: detect.binaryPath,
            installHint: detect.installHint,
            probedAt: iso8601.string(from: now),
            models: models,
            memoryTotalMB: memoryTotalMB,
            memoryUsedMB: memoryUsedMB,
            cpuLoadPercent: cpuLoadPercent,
        )
    }

    public static func modelName(fromChatBody body: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BarkVisorError.badRequest("Chat completion body must be JSON")
        }
        return try modelName(fromObject: object)
    }

    public static func modelName(fromObject object: [String: Any]) throws -> String {
        guard let model = object["model"] as? String else {
            throw BarkVisorError.badRequest("Chat completion requires model")
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BarkVisorError.badRequest("Chat completion requires model")
        }
        return trimmed
    }
}
