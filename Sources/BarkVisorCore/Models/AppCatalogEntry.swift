import Foundation
import GRDB

public struct AppCatalogEnvVar: Codable, Equatable, Sendable {
    public var name: String
    public var defaultValue: String?
    public var required: Bool
    public var description: String?
    public var kind: String
    public var options: [String]?

    public init(
        name: String,
        defaultValue: String? = nil,
        required: Bool = false,
        description: String? = nil,
        kind: String = "text",
        options: [String]? = nil,
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.required = required
        self.description = description
        self.kind = kind
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case name
        case defaultValue = "default"
        case required
        case description
        case kind
        case options
    }
}

public struct AppCatalogVolume: Codable, Equatable, Sendable {
    public var containerPath: String
    public var description: String?
    public var name: String?
    public var kind: String

    public init(
        containerPath: String,
        description: String? = nil,
        name: String? = nil,
        kind: String = "volume",
    ) {
        self.containerPath = containerPath
        self.description = description
        self.name = name
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case containerPath = "container"
        case description
        case name
        case kind
    }
}

public struct AppCatalogPort: Codable, Equatable, Sendable {
    public var container: Int?
    public var host: Int?
    public var proto: String
    public var ui: Bool
    public var description: String?

    public init(
        container: Int? = nil,
        host: Int? = nil,
        proto: String = "tcp",
        ui: Bool = false,
        description: String? = nil,
    ) {
        self.container = container
        self.host = host
        self.proto = proto
        self.ui = ui
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case container
        case host
        case proto = "protocol"
        case ui
        case description
    }
}

public struct AppCatalogUI: Codable, Equatable, Sendable {
    public var scheme: String
    public var path: String
    public var tips: [String: String]
    public var proxy: String
    public var basePathEnv: [String]

    public init(
        scheme: String = "http",
        path: String = "",
        tips: [String: String] = [:],
        proxy: String = "direct",
        basePathEnv: [String] = [],
    ) {
        self.scheme = scheme
        self.path = path
        self.tips = tips
        self.proxy = proxy
        self.basePathEnv = basePathEnv
    }
}

public struct AppCatalogDocument: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int
    public var source: String
    public var apps: [AppCatalogEntryDTO]

    public init(
        name: String,
        version: Int = 1,
        source: String = AppCatalogEntryDTO.bigBearSource,
        apps: [AppCatalogEntryDTO],
    ) {
        self.name = name
        self.version = version
        self.source = source
        self.apps = apps
    }
}

public struct AppCatalogEntryDTO: Codable, Equatable, Sendable {
    public static let bigBearSource = "big-bear-universal"
    public static let linuxServerSource = "linuxserver"

    public var id: String
    public var name: String
    public var tagline: String?
    public var description: String?
    public var iconUrl: String?
    public var category: String
    public var arches: [String]
    public var source: String
    public var compose: String
    public var envSchema: [AppCatalogEnvVar]
    public var volumes: [AppCatalogVolume]
    public var ports: [AppCatalogPort]
    public var image: String?
    public var digest: String?
    public var unsupportedReasons: [String]
    public var ui: AppCatalogUI
    public var fields: [AppTemplateField]?

    public init(
        id: String,
        name: String,
        tagline: String? = nil,
        description: String? = nil,
        iconUrl: String? = nil,
        category: String,
        arches: [String],
        source: String = AppCatalogEntryDTO.bigBearSource,
        compose: String,
        envSchema: [AppCatalogEnvVar] = [],
        volumes: [AppCatalogVolume] = [],
        ports: [AppCatalogPort] = [],
        image: String? = nil,
        digest: String? = nil,
        unsupportedReasons: [String] = [],
        ui: AppCatalogUI = AppCatalogUI(),
        fields: [AppTemplateField]? = nil,
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.description = description
        self.iconUrl = iconUrl
        self.category = category
        self.arches = arches
        self.source = source
        self.compose = compose
        self.envSchema = envSchema
        self.volumes = volumes
        self.ports = ports
        self.image = image
        self.digest = digest
        self.unsupportedReasons = unsupportedReasons
        self.ui = ui
        self.fields = fields
    }

    public var isInstallable: Bool {
        unsupportedReasons.isEmpty
    }

    public func supports(deviceArch: String) -> Bool {
        AppCatalogArch.supports(arches: arches, deviceArch: deviceArch)
    }

    public func applicationDocument(name: String) -> [String: Any] {
        [
            "apiVersion": "barkvisor.dev/v1",
            "kind": WorkloadSpec.kindApplication,
            "metadata": ["name": name],
            "spec": [
                "runtime": WorkloadSpec.runtimeDevice,
                "compose": compose,
            ],
        ]
    }
}

public enum AppCatalogArch {
    public static func supports(arches: [String], deviceArch: String) -> Bool {
        if arches.isEmpty { return true }
        let want = PlatformCapabilities.normalizedArch(deviceArch)
        return arches.contains { PlatformCapabilities.normalizedArch($0) == want }
    }
}

public struct AppCatalogRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "app_catalog"

    public var id: String
    public var repositoryId: String
    public var slug: String
    public var name: String
    public var tagline: String?
    public var description: String?
    public var iconUrl: String?
    public var category: String
    public var archesJson: String?
    public var source: String
    public var composeYaml: String
    public var envSchemaJson: String?
    public var volumesJson: String?
    public var portsJson: String?
    public var image: String?
    public var digest: String?
    public var unsupportedReasonsJson: String?
    public var uiJson: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        repositoryId: String,
        slug: String,
        name: String,
        tagline: String?,
        description: String?,
        iconUrl: String?,
        category: String,
        archesJson: String?,
        source: String,
        composeYaml: String,
        envSchemaJson: String?,
        volumesJson: String?,
        portsJson: String?,
        image: String?,
        digest: String?,
        unsupportedReasonsJson: String?,
        uiJson: String?,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.slug = slug
        self.name = name
        self.tagline = tagline
        self.description = description
        self.iconUrl = iconUrl
        self.category = category
        self.archesJson = archesJson
        self.source = source
        self.composeYaml = composeYaml
        self.envSchemaJson = envSchemaJson
        self.volumesJson = volumesJson
        self.portsJson = portsJson
        self.image = image
        self.digest = digest
        self.unsupportedReasonsJson = unsupportedReasonsJson
        self.uiJson = uiJson
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func dto() -> AppCatalogEntryDTO {
        var dto = AppCatalogEntryDTO(
            id: slug,
            name: name,
            tagline: tagline,
            description: description,
            iconUrl: iconUrl,
            category: category,
            arches: JSONColumnCoding.decodeArrayOrEmpty(String.self, from: archesJson),
            source: source,
            compose: composeYaml,
            envSchema: JSONColumnCoding.decodeArrayOrEmpty(AppCatalogEnvVar.self, from: envSchemaJson),
            volumes: JSONColumnCoding.decodeArrayOrEmpty(AppCatalogVolume.self, from: volumesJson),
            ports: JSONColumnCoding.decodeArrayOrEmpty(AppCatalogPort.self, from: portsJson),
            image: image,
            digest: digest,
            unsupportedReasons: JSONColumnCoding.decodeArrayOrEmpty(
                String.self, from: unsupportedReasonsJson,
            ),
            ui: JSONColumnCoding.decode(AppCatalogUI.self, from: uiJson) ?? AppCatalogUI(),
        )
        let prefill = AppTemplate.devicePrefill()
        dto.fields = AppTemplate.fields(
            from: dto,
            puid: prefill.puid,
            pgid: prefill.pgid,
            timezone: prefill.timezone,
        )
        return dto
    }

    public static func from(dto: AppCatalogEntryDTO, repositoryId: String, now: String) -> AppCatalogRecord {
        AppCatalogRecord(
            id: UUID().uuidString,
            repositoryId: repositoryId,
            slug: dto.id,
            name: dto.name,
            tagline: dto.tagline,
            description: dto.description,
            iconUrl: dto.iconUrl,
            category: dto.category,
            archesJson: JSONColumnCoding.encodeArrayOrNil(dto.arches),
            source: dto.source,
            composeYaml: dto.compose,
            envSchemaJson: JSONColumnCoding.encode(dto.envSchema),
            volumesJson: JSONColumnCoding.encode(dto.volumes),
            portsJson: JSONColumnCoding.encode(dto.ports),
            image: dto.image,
            digest: dto.digest,
            unsupportedReasonsJson: JSONColumnCoding.encodeArrayOrNil(dto.unsupportedReasons),
            uiJson: JSONColumnCoding.encode(dto.ui),
            createdAt: now,
            updatedAt: now,
        )
    }
}
