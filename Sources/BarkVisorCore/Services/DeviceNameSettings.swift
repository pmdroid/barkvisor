import Foundation
import GRDB

public enum DeviceNameSettings {
    public static let key = "device_display_name"
    public static let maxLength = 64

    public static func defaultName(hostname: String = ProcessInfo.processInfo.hostName) -> String {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Device" : trimmed
    }

    public static func parse(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BarkVisorError.badRequest("Device name must not be empty")
        }
        guard trimmed.count <= maxLength else {
            throw BarkVisorError.badRequest("Device name must be \(maxLength) characters or fewer")
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw BarkVisorError.badRequest("Device name cannot contain control characters")
        }
        return trimmed
    }

    public static func resolved(
        from db: Database,
        hostname: String = ProcessInfo.processInfo.hostName,
    ) throws -> String {
        let stored = try AppSetting.fetchOne(db, key: key)?.value ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultName(hostname: hostname) }
        return trimmed
    }

    @discardableResult
    public static func save(_ raw: String, db: Database) throws -> String {
        let parsed = try parse(raw)
        try AppSetting(key: key, value: parsed).save(db, onConflict: .replace)
        return parsed
    }
}
