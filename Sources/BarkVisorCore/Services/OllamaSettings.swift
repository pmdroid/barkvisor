import Foundation
import GRDB

/// Per-Device upstream Ollama key + loopback URL. Clients never see the key (PAS-269).
public enum OllamaSettings {
    public static let endpointKey = "ollama.endpoint"
    public static let apiKeyKey = "ollama.api_key"

    public static func load(from db: Database) throws -> (endpoint: URL, apiKey: String?) {
        let endpointRaw = try AppSetting.fetchOne(db, key: endpointKey)?.value
        let endpoint = try OllamaEndpoint.parse(endpointRaw)
        let rawKey = try AppSetting.fetchOne(db, key: apiKeyKey)?.value ?? ""
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmedKey.isEmpty ? nil : trimmedKey
        return (endpoint, key)
    }

    public static func snapshot(from db: Database) throws -> OllamaSettingsSnapshot {
        let loaded = try load(from: db)
        return OllamaSettingsSnapshot(endpoint: loaded.endpoint.absoluteString, hasApiKey: loaded.apiKey != nil)
    }

    public static func save(
        endpoint: String?,
        apiKey: String?,
        updateApiKey: Bool,
        db: Database,
    ) throws -> OllamaSettingsSnapshot {
        if let endpoint {
            let url = try OllamaEndpoint.parse(endpoint)
            try AppSetting(key: endpointKey, value: url.absoluteString).save(db, onConflict: .replace)
        }
        if updateApiKey {
            let trimmed = (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                _ = try AppSetting.deleteOne(db, key: apiKeyKey)
            } else {
                try AppSetting(key: apiKeyKey, value: trimmed).save(db, onConflict: .replace)
            }
        }
        return try snapshot(from: db)
    }
}
