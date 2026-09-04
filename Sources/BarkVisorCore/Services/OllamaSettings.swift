#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB

/// Per-Device upstream Ollama key + loopback URL. Home is authoritative.
/// Clients never see the key (PAS-269).
public enum OllamaSettings {
    public static let endpointKey = "ollama.endpoint"
    public static let apiKeyKey = "ollama.api_key"
    static let ciphertextPrefix = "barkvisor-enc1:"

    public static func maskedAPIKey(_ raw: String?) -> String? {
        nonempty(raw) == nil ? nil : "••••"
    }

    static func sealAPIKey(_ plaintext: String, secret: String) throws -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else {
            throw BarkVisorError.internalError("Unable to seal Ollama key")
        }
        return ciphertextPrefix + combined.base64EncodedString()
    }

    static func storedAPIKey(_ raw: String?, secret: String) -> String? {
        guard let raw, nonempty(raw) != nil else { return nil }
        guard raw.hasPrefix(ciphertextPrefix) else { return raw }
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let payload = Data(base64Encoded: String(raw.dropFirst(ciphertextPrefix.count))),
              let sealed = try? AES.GCM.SealedBox(combined: payload),
              let opened = try? AES.GCM.open(sealed, using: key),
              let plaintext = String(data: opened, encoding: .utf8)
        else {
            Log.server.warning("Stored Ollama key could not be decrypted; re-enter it")
            return nil
        }
        return plaintext
    }

    static func resealLegacyPlaintext(
        _ raw: String?,
        secret: String,
        write: (String) throws -> Void,
    ) {
        guard let raw, nonempty(raw) != nil, !raw.hasPrefix(ciphertextPrefix),
              storedAPIKey(raw, secret: secret) != nil
        else { return }
        do {
            try write(sealAPIKey(raw, secret: secret))
        } catch {
            Log.server.warning("Could not re-seal legacy Ollama key: \(error.localizedDescription)")
        }
    }

    public static func load(from db: Database) throws -> (endpoint: URL, apiKey: String?) {
        try load(hostId: Config.hostId, from: db)
    }

    public static func load(
        hostId: String,
        from db: Database,
        secret: String? = nil,
    ) throws -> (endpoint: URL, apiKey: String?) {
        let hostId = try requireHostId(hostId)
        let keySecret = secret ?? Config.ollamaKeySecret
        if let row = try OllamaHostSettingRecord.fetch(db, hostId: hostId) {
            let global = try loadGlobalRaw(from: db)
            let endpointRaw = nonempty(row.endpoint) ?? global.endpoint
            let apiKeyRaw = row.apiKey == nil ? global.apiKey : nonempty(row.apiKey)
            resealLegacyPlaintext(row.apiKey, secret: keySecret) { sealed in
                var resealed = row
                resealed.apiKey = sealed
                try resealed.save(db)
            }
            if row.apiKey == nil {
                resealLegacyPlaintext(global.apiKey, secret: keySecret) { sealed in
                    try AppSetting(key: apiKeyKey, value: sealed).save(db, onConflict: .replace)
                }
            }
            return try credentials(
                endpointRaw: endpointRaw,
                apiKeyRaw: storedAPIKey(apiKeyRaw, secret: keySecret),
            )
        }
        return try loadGlobal(from: db, secret: keySecret)
    }

    public static func loadGlobal(
        from db: Database,
        secret: String? = nil,
    ) throws -> (endpoint: URL, apiKey: String?) {
        let raw = try loadGlobalRaw(from: db)
        resealLegacyPlaintext(raw.apiKey, secret: secret ?? Config.ollamaKeySecret) { sealed in
            try AppSetting(key: apiKeyKey, value: sealed).save(db, onConflict: .replace)
        }
        return try credentials(
            endpointRaw: raw.endpoint,
            apiKeyRaw: storedAPIKey(raw.apiKey, secret: secret ?? Config.ollamaKeySecret),
        )
    }

    public static func snapshot(hostId: String, from db: Database) throws -> OllamaHostSettings {
        let loaded = try load(hostId: hostId, from: db)
        return OllamaHostSettings(
            hostId: hostId,
            endpoint: loaded.endpoint.absoluteString,
            hasApiKey: loaded.apiKey != nil,
            apiKeyMasked: maskedAPIKey(loaded.apiKey),
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
        selfHostId: String,
        db: Database,
        secret: String? = nil,
    ) throws -> OllamaSettingsSnapshot {
        let selfHostId = try requireHostId(selfHostId)
        let keySecret = secret ?? Config.ollamaKeySecret
        try seedSelfFromLegacy(hostId: selfHostId, db: db)
        let target = try optionalHostId(hostId) ?? selfHostId
        let existing = try OllamaHostSettingRecord.fetch(db, hostId: target)
        var row = existing ?? OllamaHostSettingRecord(hostId: target, endpoint: nil, apiKey: nil)
        if let endpoint {
            let url = try OllamaEndpoint.parse(endpoint)
            row.endpoint = url.absoluteString
        }
        if updateApiKey {
            let trimmed = (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            row.apiKey = trimmed.isEmpty ? "" : try sealAPIKey(trimmed, secret: keySecret)
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
