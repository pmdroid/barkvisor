import Foundation
import GRDB

public struct VMTemplate: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "vm_templates"

    public var id: String
    public var slug: String
    public var name: String
    public var description: String?
    public var category: String
    public var icon: String
    public var imageSlug: String
    public var cpuCount: Int
    public var memoryMB: Int
    public var diskSizeGB: Int
    public var portForwards: String? // JSON-encoded [PortForwardRule]
    public var networkMode: String // "nat" or "bridged"
    public var inputs: String // JSON-encoded [TemplateInput]
    public var userDataTemplate: String
    public var isBuiltIn: Bool
    public var repositoryId: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        slug: String,
        name: String,
        description: String?,
        category: String,
        icon: String,
        imageSlug: String,
        cpuCount: Int,
        memoryMB: Int,
        diskSizeGB: Int,
        portForwards: String?,
        networkMode: String,
        inputs: String,
        userDataTemplate: String,
        isBuiltIn: Bool,
        repositoryId: String?,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.category = category
        self.icon = icon
        self.imageSlug = imageSlug
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.portForwards = portForwards
        self.networkMode = networkMode
        self.inputs = inputs
        self.userDataTemplate = userDataTemplate
        self.isBuiltIn = isBuiltIn
        self.repositoryId = repositoryId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TemplateInput: Codable, Sendable {
    public let id: String
    public let label: String
    public let type: String // "text", "password", "textarea"
    public let `default`: String?
    public let required: Bool
    public let placeholder: String?
    public let minLength: Int?
    public let maxLength: Int?

    public init(
        id: String,
        label: String,
        type: String,
        default: String?,
        required: Bool,
        placeholder: String?,
        minLength: Int?,
        maxLength: Int?,
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.default = `default`
        self.required = required
        self.placeholder = placeholder
        self.minLength = minLength
        self.maxLength = maxLength
    }
}

public struct TemplateCatalog: Codable, Sendable {
    public let version: Int
    public let templates: [TemplateCatalogEntry]

    public init(version: Int, templates: [TemplateCatalogEntry]) {
        self.version = version
        self.templates = templates
    }
}

public struct TemplateCatalogEntry: Codable, Sendable {
    public let slug: String
    public let name: String
    public let description: String?
    public let category: String
    public let icon: String
    public let imageSlug: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let diskSizeGB: Int
    public let portForwards: [PortForwardRule]
    public let networkMode: String? // "nat" (default) or "bridged"
    public let inputs: [TemplateInput]
    public let userDataTemplate: String

    public init(
        slug: String,
        name: String,
        description: String?,
        category: String,
        icon: String,
        imageSlug: String,
        cpuCount: Int,
        memoryMB: Int,
        diskSizeGB: Int,
        portForwards: [PortForwardRule],
        networkMode: String?,
        inputs: [TemplateInput],
        userDataTemplate: String,
    ) {
        self.slug = slug
        self.name = name
        self.description = description
        self.category = category
        self.icon = icon
        self.imageSlug = imageSlug
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.portForwards = portForwards
        self.networkMode = networkMode
        self.inputs = inputs
        self.userDataTemplate = userDataTemplate
    }
}
