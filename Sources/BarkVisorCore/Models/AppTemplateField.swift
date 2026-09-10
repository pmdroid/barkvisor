import Foundation

public struct AppTemplateField: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
    public var kind: String
    public var required: Bool
    public var defaultValue: String?
    public var target: String
    public var placeholder: String?
    public var options: [String]?

    public init(
        id: String,
        label: String,
        description: String? = nil,
        kind: String,
        required: Bool = false,
        defaultValue: String? = nil,
        target: String,
        placeholder: String? = nil,
        options: [String]? = nil,
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.target = target
        self.placeholder = placeholder
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case description
        case kind
        case required
        case defaultValue = "default"
        case target
        case placeholder
        case options
    }

    public var envName: String? {
        guard target.hasPrefix("env:") else { return nil }
        return String(target.dropFirst(4))
    }

    public var volumePath: String? {
        guard target.hasPrefix("volume:") else { return nil }
        return String(target.dropFirst(7))
    }

    public var portSpec: (container: Int, proto: String)? {
        guard target.hasPrefix("port:") else { return nil }
        let rest = String(target.dropFirst(5))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard let container = Int(parts[0]) else { return nil }
        let proto = parts.count > 1 ? parts[1].lowercased() : "tcp"
        return (container, proto)
    }
}
