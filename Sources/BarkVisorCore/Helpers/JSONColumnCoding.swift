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
}
