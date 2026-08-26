import Foundation
import GRDB

public enum InferenceBackendKind: String, Codable, Sendable, CaseIterable {
    case ollama
    case unsloth

    public static func parseStored(_ raw: String?) -> InferenceBackendKind {
        guard let raw else { return .ollama }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return InferenceBackendKind(rawValue: trimmed) ?? .ollama
    }
}

public enum InferenceSettings {
    public static func key(hostId: String) -> String {
        "inference.backend.\(hostId)"
    }

    public static func load(hostId: String, from db: Database) throws -> InferenceBackendKind {
        let stored = try AppSetting.fetchOne(db, key: key(hostId: hostId))?.value
        return InferenceBackendKind.parseStored(stored)
    }

    public static func save(_ kind: InferenceBackendKind, hostId: String, db: Database) throws {
        try AppSetting(key: key(hostId: hostId), value: kind.rawValue)
            .save(db, onConflict: .replace)
    }

    public static func storedRaw(hostId: String, from db: Database) throws -> String? {
        let kind = try load(hostId: hostId, from: db)
        return kind == .ollama ? nil : kind.rawValue
    }
}
