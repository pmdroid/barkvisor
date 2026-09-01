import Foundation

struct VMTemplateRecord: Decodable, Identifiable, Hashable {
    var id: String
    var slug: String
    var name: String
    var description: String?
    var category: String
    var icon: String
    var imageSlug: String
    var cpuCount: Int
    var memoryMB: Int
    var diskSizeGB: Int
    var networkMode: String?
    var inputs: [TemplateInputRecord]?
    var userDataTemplate: String?
    var architectures: [String]?
    var minMemoryMB: Int?
    var requiredFeatures: [String]?
    var compatible: Bool?
    var catalogImages: [TemplateCatalogImageRecord]?

    var tagline: String {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Ready-made Workload template" : trimmed
    }

    var declaresSSHKeys: Bool {
        (inputs ?? []).contains { $0.id == "ssh_keys" }
    }

    var visibleInputs: [TemplateInputRecord] {
        (inputs ?? []).filter { $0.id != "ssh_keys" }
    }
}

struct TemplateInputRecord: Decodable, Hashable, Encodable {
    var id: String
    var label: String?
    var type: String
    var required: Bool?
    var `default`: String?
    var minLength: Int?

    init(
        id: String,
        label: String? = nil,
        type: String = "text",
        required: Bool? = nil,
        default defaultValue: String? = nil,
        minLength: Int? = nil,
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.required = required
        self.default = defaultValue
        self.minLength = minLength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        if let decoded = try container.decodeIfPresent(String.self, forKey: .type) {
            type = decoded
        } else {
            type = id == "ssh_keys" ? "textarea" : "text"
        }
        required = try container.decodeIfPresent(Bool.self, forKey: .required)
        `default` = try container.decodeIfPresent(String.self, forKey: .default)
        minLength = try container.decodeIfPresent(Int.self, forKey: .minLength)
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, type, required
        case `default`
        case minLength
    }
}

struct TemplateCatalogImageRecord: Decodable, Hashable {
    var slug: String
    var name: String
    var imageType: String
    var arch: String
    var downloadUrl: String
    var sha256: String?
    var sha512: String?
}

struct DeployRecipeImageBody: Encodable {
    var downloadUrl: String
    var arch: String
    var imageType: String
    var sha256: String?
    var sha512: String?
    var name: String?
    var slug: String?
}

struct DeployRecipeBody: Encodable {
    var name: String?
    var slug: String?
    var inputs: [TemplateInputRecord]
    var userDataTemplate: String
    var cpuCount: Int
    var memoryMB: Int
    var diskSizeGB: Int
    var networkMode: String?
    var architectures: [String]?
    var minMemoryMB: Int?
    var requiredFeatures: [String]?
    var image: DeployRecipeImageBody
}

struct CreateSSHKeyBody: Encodable, Equatable {
    var name: String
    var publicKey: String
}

struct SSHKeyRecord: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var publicKey: String
    var fingerprint: String
    var keyType: String
    var isDefault: Bool
    var createdAt: String

    /// Same shape as web `authorizedKeyForCloudInit` (public key + Home key name comment).
    var cloudInitAuthorizedKey: String {
        let text = publicKey
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if comment.isEmpty { return text }
        let parts = text.split(whereSeparator: \.isWhitespace)
        if parts.count >= 3, parts[2...].joined(separator: " ") == comment { return text }
        return "\(text) \(comment)"
    }
}

struct DeployTemplateBody: Encodable {
    var templateId: String
    var vmName: String
    var inputs: [String: String]
    var cpuCount: Int?
    var memoryMB: Int?
    var diskSizeGB: Int?
    var networkId: String?
    /// Catalog recipe for deploy when the template row is not on the target Device (same as web wizard).
    var recipe: DeployRecipeBody?
}

struct DeployTemplateResponse: Decodable {
    var status: String
    var imageId: String?
    var taskID: String?
    var vm: Workload?
}

struct PasskeyCeremonyBegin: Decodable {
    var sessionId: String
    var publicKey: JSONDictionary
}

struct PasskeyLoginFinishBody: Encodable {
    var sessionId: String
    var credential: JSONEncodable
}

/// Loose JSON object from passkey begin / finish ceremonies.
struct JSONDictionary: Decodable {
    var value: [String: Any]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode([String: JSONValue].self).mapValues(\.any)
    }
}

struct JSONEncodable: Encodable {
    var value: [String: Any]

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.mapValues(JSONValue.init(any:)))
    }
}

private enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as Int: self = .int(value)
        case let value as Double: self = .double(value)
        case let value as Bool: self = .bool(value)
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case let .string(value): value
        case let .int(value): value
        case let .double(value): value
        case let .bool(value): value
        case let .object(value): value.mapValues(\.any)
        case let .array(value): value.map(\.any)
        case .null: NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
