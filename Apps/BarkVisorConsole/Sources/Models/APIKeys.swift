import Foundation

/// Live route group is `/api/auth/keys`, not `/api/keys`.
enum APIKeyRoutes {
    static let collection = "/api/auth/keys"

    static func item(_ id: String) -> String {
        "\(collection)/\(id)"
    }
}

enum APIKeyKindOption: String, CaseIterable, Identifiable {
    case inference
    case full

    var id: String {
        rawValue
    }

    static let createDefault = APIKeyKindOption.inference

    var pickerLabel: String {
        switch self {
        case .inference: "Inference"
        case .full: "Full"
        }
    }

    static func badge(_ raw: String?) -> String {
        raw == full.rawValue ? full.rawValue : inference.rawValue
    }
}

/// List DTO. Matches web `APIKeyResponse`. Never includes the plaintext secret.
struct APIKeyResponse: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var keyPrefix: String
    var expiresAt: String?
    var lastUsedAt: String?
    var createdAt: String
    var kind: String

    private enum CodingKeys: String, CodingKey {
        case id, name, keyPrefix, expiresAt, lastUsedAt, createdAt, kind
    }

    init(
        id: String,
        name: String,
        keyPrefix: String,
        expiresAt: String?,
        lastUsedAt: String?,
        createdAt: String,
        kind: String = APIKeyKindOption.full.rawValue,
    ) {
        self.id = id
        self.name = name
        self.keyPrefix = keyPrefix
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyPrefix = try container.decode(String.self, forKey: .keyPrefix)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        lastUsedAt = try container.decodeIfPresent(String.self, forKey: .lastUsedAt)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? APIKeyKindOption.full.rawValue
    }

    var kindBadge: String {
        APIKeyKindOption.badge(kind)
    }

    var hasSecretField: Bool {
        Mirror(reflecting: self).children.contains { $0.label == "key" }
    }
}

/// Create DTO. Matches web `APIKeyCreateResponse`. `key` is shown once.
struct APIKeyCreateResponse: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var key: String
    var keyPrefix: String
    var expiresAt: String?
    var createdAt: String
    var kind: String

    private enum CodingKeys: String, CodingKey {
        case id, name, key, keyPrefix, expiresAt, createdAt, kind
    }

    init(
        id: String,
        name: String,
        key: String,
        keyPrefix: String,
        expiresAt: String?,
        createdAt: String,
        kind: String = APIKeyKindOption.full.rawValue,
    ) {
        self.id = id
        self.name = name
        self.key = key
        self.keyPrefix = keyPrefix
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        key = try container.decode(String.self, forKey: .key)
        keyPrefix = try container.decode(String.self, forKey: .keyPrefix)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? APIKeyKindOption.full.rawValue
    }
}

struct APIKeyCreateBody: Encodable, Equatable {
    var name: String
    var expiresIn: String
    var kind: String
}

enum APIKeyDisplay {
    static let inferenceCopy = "inference = Ollama list + chat completions only"
    static let forbiddenFallback = "API keys are admin-only."
    static let signInRequired = "Sign in required"
    static let expiryChoices = ["30d", "90d", "1y", "never"]
    static let defaultExpiry = "90d"

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let shortDate = posixFormatter("yyyy-MM-dd")
    private static let shortDateTime = posixFormatter("yyyy-MM-dd HH:mm")

    static func expiryLabel(_ expiresAt: String?, now: Date = Date()) -> String {
        guard let expiresAt else { return "Never" }
        guard let date = parseISO8601(expiresAt) else { return expiresAt }
        if date < now { return "Expired" }
        return shortDate.string(from: date)
    }

    static func usedLabel(_ lastUsedAt: String?) -> String {
        guard let lastUsedAt else { return "Never" }
        guard let date = parseISO8601(lastUsedAt) else { return lastUsedAt }
        return shortDateTime.string(from: date)
    }

    static func createdLabel(_ createdAt: String) -> String {
        guard let date = parseISO8601(createdAt) else { return createdAt }
        return shortDate.string(from: date)
    }

    static func forbiddenMessage(from error: Error) -> String? {
        guard let api = error as? APIError, case let .http(status, reason) = api, status == 403 else {
            return nil
        }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? forbiddenFallback : trimmed
    }

    static func parseISO8601(_ raw: String) -> Date? {
        if let date = iso8601Fractional.date(from: raw) { return date }
        return iso8601Whole.date(from: raw)
    }

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}
