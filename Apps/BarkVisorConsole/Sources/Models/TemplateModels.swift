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
    var compatible: Bool?

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

struct TemplateInputRecord: Decodable, Hashable {
    var id: String
    var label: String?
    var required: Bool?
    var `default`: String?
    var minLength: Int?
}

struct SSHKeyRecord: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var publicKey: String
    var fingerprint: String
    var keyType: String
    var isDefault: Bool
    var createdAt: String
}

struct DeployTemplateBody: Encodable {
    var templateId: String
    var vmName: String
    var inputs: [String: String]
    var cpuCount: Int?
    var memoryMB: Int?
    var diskSizeGB: Int?
    var networkId: String?
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
