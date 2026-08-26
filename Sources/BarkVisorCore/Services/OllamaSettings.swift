import Foundation
import GRDB

/// Per-Device upstream Ollama key + loopback URL. Home is authoritative.
/// Clients never see the key (PAS-269).
public enum OllamaSettings {
    public static let endpointKey = "ollama.endpoint"
    public static let apiKeyKey = "ollama.api_key"

    public static func maskedAPIKey(_ raw: String?) -> String? {
        nonempty(raw) == nil ? nil : "••••"
    }

    public static func load(from db: Database) throws -> (endpoint: URL, apiKey: String?) {
        try load(hostId: Config.hostId, from: db)
    }

    public static func load(hostId: String, from db: Database) throws -> (endpoint: URL, apiKey: String?) {
        let hostId = try requireHostId(hostId)
        if let row = try OllamaHostSettingRecord.fetch(db, hostId: hostId) {
            let global = try loadGlobalRaw(from: db)
            let endpointRaw = nonempty(row.endpoint) ?? global.endpoint
            // NULL apiKey inherits the global key; empty string is an explicit clear.
            let apiKeyRaw = row.apiKey == nil ? global.apiKey : nonempty(row.apiKey)
            return try credentials(endpointRaw: endpointRaw, apiKeyRaw: apiKeyRaw)
        }
        return try loadGlobal(from: db)
    }

    public static func loadGlobal(from db: Database) throws -> (endpoint: URL, apiKey: String?) {
        let raw = try loadGlobalRaw(from: db)
        return try credentials(endpointRaw: raw.endpoint, apiKeyRaw: raw.apiKey)
    }

    public static func snapshot(hostId: String, from db: Database) throws -> OllamaHostSettings {
        let loaded = try load(hostId: hostId, from: db)
        return try OllamaHostSettings(
            hostId: hostId,
            endpoint: loaded.endpoint.absoluteString,
            hasApiKey: loaded.apiKey != nil,
            apiKeyMasked: maskedAPIKey(loaded.apiKey),
            backend: InferenceSettings.storedRaw(hostId: hostId, from: db),
        )
    }

    public static func list(
        knownHostIds: [String] = [],
        selfHostId: String,
        from db: Database,
    ) throws -> OllamaSettingsSnapshot {
        try seedSelfFromLegacy(hostId: selfHostId, db: db)
        let stored = try OllamaHostSettingRecord.fetchAll(db).map(\.hostId)
        var ids: [String] = []
        var seen = Set<String>()
        for id in [selfHostId] + knownHostIds + stored {
            guard let trimmed = try? requireHostId(id), seen.insert(trimmed).inserted else { continue }
            ids.append(trimmed)
        }
        return try OllamaSettingsSnapshot(
            hosts: ids.map { try snapshot(hostId: $0, from: db) },
        )
    }

    public static func save(
        hostId: String?,
        endpoint: String?,
        apiKey: String?,
        updateApiKey: Bool,
        backend: String? = nil,
        selfHostId: String,
        db: Database,
    ) throws -> OllamaSettingsSnapshot {
        let selfHostId = try requireHostId(selfHostId)
        try seedSelfFromLegacy(hostId: selfHostId, db: db)
        let target = try optionalHostId(hostId) ?? selfHostId
        if let backend {
            try InferenceSettings.save(InferenceBackendKind.parseStored(backend), hostId: target, db: db)
        }
        let existing = try OllamaHostSettingRecord.fetch(db, hostId: target)
        var row = existing ?? OllamaHostSettingRecord(hostId: target, endpoint: nil, apiKey: nil)
        if let endpoint {
            let url = try OllamaEndpoint.parse(endpoint)
            row.endpoint = url.absoluteString
        }
        if updateApiKey {
            // Persist "" as an explicit clear (no inherit). Do not coerce empty to nil.
            row.apiKey = (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try row.save(db)
        return try list(knownHostIds: [target], selfHostId: selfHostId, from: db)
    }

    /// Copy the legacy global pair onto the self Device once. Leaves the global row in place.
    public static func seedSelfFromLegacy(hostId: String, db: Database) throws {
        guard let trimmedHost = try optionalHostId(hostId) else { return }
        if try OllamaHostSettingRecord.fetch(db, hostId: trimmedHost) != nil { return }
        let global = try loadGlobalRaw(from: db)
        guard global.endpoint != nil || global.apiKey != nil else { return }
        try OllamaHostSettingRecord(
            hostId: trimmedHost,
            endpoint: global.endpoint,
            apiKey: global.apiKey,
        ).insert(db)
    }

    public static func client(hostId: String, from db: Database) throws -> OllamaClient {
        let loaded = try load(hostId: hostId, from: db)
        return OllamaClient(baseURL: loaded.endpoint, apiKey: loaded.apiKey)
    }

    private static func loadGlobalRaw(from db: Database) throws -> (endpoint: String?, apiKey: String?) {
        let endpoint = try AppSetting.fetchOne(db, key: endpointKey)?.value
        let apiKey = try AppSetting.fetchOne(db, key: apiKeyKey)?.value
        return (nonempty(endpoint), nonempty(apiKey))
    }

    private static func credentials(
        endpointRaw: String?,
        apiKeyRaw: String?,
    ) throws -> (endpoint: URL, apiKey: String?) {
        let endpoint = try OllamaEndpoint.parse(endpointRaw)
        return (endpoint, nonempty(apiKeyRaw))
    }

    private static func nonempty(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalHostId(_ raw: String?) throws -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("\0") {
            throw BarkVisorError.badRequest("Device id is invalid")
        }
        return trimmed
    }

    private static func requireHostId(_ raw: String?) throws -> String {
        guard let hostId = try optionalHostId(raw) else {
            throw BarkVisorError.badRequest("hostId is required")
        }
        return hostId
    }
}

struct OllamaHostSettingRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "ollama_host_settings"

    var hostId: String
    var endpoint: String?
    var apiKey: String?

    static func fetch(_ db: Database, hostId: String) throws -> OllamaHostSettingRecord? {
        try filter(Column("hostId") == hostId).fetchOne(db)
    }
}
