import Foundation

/// Helpers for encoding/decoding JSON stored in SQLite TEXT columns.
public enum JSONColumnCoding {
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    /// Decode a JSON string column into a typed array. Returns nil if the column is nil or decoding fails.
    public static func decodeArray<T: Decodable>(_ type: T.Type = T.self, from json: String?) -> [T]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode([T].self, from: data)
    }

    /// Decode a JSON array column.
    /// - Returns: empty when nil/blank; empty (and optional log) when corrupt — never throws.
    /// Policy for VM JSON columns: prefer launch/list over hard failure on bad data.
    public static func decodeArrayOrEmpty<T: Decodable>(
        _ type: T.Type = T.self,
        from json: String?,
        column: String? = nil,
        log: ((String) -> Void)? = nil,
    ) -> [T] {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else {
            return []
        }
        do {
            return try decoder.decode([T].self, from: data)
        } catch {
            if let column {
                let msg = "Failed to decode JSON column '\(column)': \(error)"
                if let log {
                    log(msg)
                } else {
                    Log.vm.warning(msg)
                }
            }
            return []
        }
    }

    /// Decode a JSON string column into a typed value. Returns nil if the column is nil or decoding fails.
    public static func decode<T: Decodable>(_ type: T.Type = T.self, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Encode a value to a JSON string for storage in a TEXT column. Returns nil if encoding fails.
    public static func encode(_ value: (some Encodable)?) -> String? {
        guard let value else { return nil }
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Encode an array for a TEXT column; empty arrays become `nil` (column cleared).
    public static func encodeArrayOrNil(_ value: [some Encodable]?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return encode(value)
    }
}
