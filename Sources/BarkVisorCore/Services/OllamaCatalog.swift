import Foundation

/// Merge Ollama `GET /api/tags` + `GET /api/ps` into one catalog (PAS-269).
public enum OllamaCatalog {
    /// Fold pulled tags and running processes for one Device.
    public static func merge(
        tags: [OllamaTagRecord],
        running: [OllamaRunningRecord],
    ) -> [OllamaLocalModel] {
        var runningByKey: [String: OllamaRunningRecord] = [:]
        for row in running {
            runningByKey[OllamaModelName.canonical(row.name)] = row
        }

        var seen: Set<String> = []
        var models: [OllamaLocalModel] = []
        for tag in tags {
            let key = OllamaModelName.canonical(tag.name)
            if seen.contains(key) { continue }
            seen.insert(key)
            let live = runningByKey[key]
            models.append(
                OllamaLocalModel(
                    name: tag.name,
                    digest: tag.digest ?? live?.digest,
                    size: tag.size ?? live?.size,
                    sizeVRAM: live?.sizeVRAM,
                    running: live != nil,
                    parameterSize: tag.parameterSize,
                    quantization: tag.quantization,
                ),
            )
        }
        for row in running {
            let key = OllamaModelName.canonical(row.name)
            if seen.contains(key) { continue }
            seen.insert(key)
            models.append(
                OllamaLocalModel(
                    name: row.name,
                    digest: row.digest,
                    size: row.size,
                    sizeVRAM: row.sizeVRAM,
                    running: true,
                ),
            )
        }
        return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func nativeTags(from models: [OllamaLocalModel]) -> OllamaNativeTags {
        OllamaNativeTags(
            models: models.map {
                OllamaNativeTag(name: $0.name, model: $0.name, size: $0.size, digest: $0.digest)
            },
        )
    }

    public static func nativePS(from models: [OllamaLocalModel]) -> OllamaNativePS {
        OllamaNativePS(
            models: models.filter(\.running).map {
                OllamaNativePSModel(
                    name: $0.name,
                    model: $0.name,
                    size: $0.size,
                    digest: $0.digest,
                    sizeVRAM: $0.sizeVRAM,
                )
            },
        )
    }
}

public enum OllamaModelName {
    public static func canonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return trimmed }
        if trimmed.contains(":") { return trimmed }
        return trimmed + ":latest"
    }

    public static func matches(_ requested: String, available: String) -> Bool {
        canonical(requested) == canonical(available)
    }
}
