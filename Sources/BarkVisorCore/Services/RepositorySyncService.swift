import Foundation
import GRDB

/// JSON schema for external repository catalogs
public struct RepoCatalog: Codable, Sendable {
    public let name: String
    public let version: Int
    public let images: [RepoCatalogImage]
    public let templates: [RepoCatalogTemplate]?

    public init(
        name: String,
        version: Int,
        images: [RepoCatalogImage],
        templates: [RepoCatalogTemplate]?,
    ) {
        self.name = name
        self.version = version
        self.images = images
        self.templates = templates
    }
}

public struct RepoCatalogTemplate: Codable, Sendable {
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
    public let networkMode: String?
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

public struct RepoCatalogImage: Codable, Sendable {
    public let slug: String
    public let name: String
    public let description: String?
    public let imageType: String
    public let arch: String
    public let version: String?
    public let downloadUrl: String
    public let sizeBytes: Int64?
    public let sha256: String?
    public let sha512: String?

    public init(
        slug: String,
        name: String,
        description: String?,
        imageType: String,
        arch: String,
        version: String?,
        downloadUrl: String,
        sizeBytes: Int64?,
        sha256: String? = nil,
        sha512: String? = nil,
    ) {
        self.slug = slug
        self.name = name
        self.description = description
        self.imageType = imageType
        self.arch = arch
        self.version = version
        self.downloadUrl = downloadUrl
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.sha512 = sha512
    }
}

/// Fetches repository JSON catalogs and upserts catalog rows into the database
public actor RepositorySyncService {
    private let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    public func sync(repositoryID: String) async throws {
        let repo = try await dbPool.read { db in
            try ImageRepository.fetchOne(db, key: repositoryID)
        }
        guard let repo else { throw BarkVisorError.repositoryNotFound(repositoryID) }

        do {
            let catalog = try await fetchCatalog(repo: repo)

            try await dbPool.write { db in
                try syncImages(db: db, repositoryID: repositoryID, catalog: catalog)
                try syncTemplates(db: db, repositoryID: repositoryID, catalog: catalog)

                let now = iso8601.string(from: Date())
                try db.execute(
                    sql:
                    "UPDATE image_repositories SET lastSyncedAt = ?, lastError = NULL, updatedAt = ? WHERE id = ?",
                    arguments: [now, now, repositoryID],
                )
            }

            let templateCount = catalog.templates?.count ?? 0
            Log.sync.info(
                "Synced repository '\(repo.name)': \(catalog.images.count) images, \(templateCount) templates",
            )
        } catch {
            let now = iso8601.string(from: Date())
            try? await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE image_repositories SET lastError = ?, updatedAt = ? WHERE id = ?",
                    arguments: [error.localizedDescription, now, repositoryID],
                )
            }
            throw error
        }
    }

    private func fetchCatalog(repo: ImageRepository) async throws -> RepoCatalog {
        guard let url = URL(string: repo.url) else {
            throw BarkVisorError.repositorySyncFailed("Invalid URL: \(repo.url)")
        }

        // SSRF protection: validate URL does not target private/internal hosts.
        // This check runs at sync time (not just repo creation) to defend against
        // DNS rebinding where a hostname's resolution changes after initial validation.
        if let ssrfError = SSRFGuard.validate(url: url) {
            throw BarkVisorError.repositorySyncFailed(ssrfError)
        }

        let maxCatalogSize = 10 * 1_024 * 1_024
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw BarkVisorError.repositorySyncFailed("HTTP error fetching \(repo.url)")
        }
        guard data.count <= maxCatalogSize else {
            throw BarkVisorError.repositorySyncFailed(
                "Catalog exceeds \(maxCatalogSize / (1_024 * 1_024)) MB size limit",
            )
        }

        if let full = try? JSONDecoder().decode(RepoCatalog.self, from: data) {
            return full
        }

        let templateCatalog = try JSONDecoder().decode(TemplateCatalog.self, from: data)
        return RepoCatalog(
            name: repo.name,
            version: templateCatalog.version,
            images: [],
            templates: templateCatalog.templates.map { entry in
                RepoCatalogTemplate(
                    slug: entry.slug, name: entry.name, description: entry.description,
                    category: entry.category, icon: entry.icon, imageSlug: entry.imageSlug,
                    cpuCount: entry.cpuCount, memoryMB: entry.memoryMB, diskSizeGB: entry.diskSizeGB,
                    portForwards: entry.portForwards, networkMode: entry.networkMode,
                    inputs: entry.inputs, userDataTemplate: entry.userDataTemplate,
                )
            },
        )
    }

    private nonisolated func syncImages(
        db: GRDB.Database, repositoryID: String, catalog: RepoCatalog,
    ) throws {
        try RepositoryImage.filter(Column("repositoryId") == repositoryID).deleteAll(db)

        for entry in catalog.images {
            let img = RepositoryImage(
                id: UUID().uuidString,
                repositoryId: repositoryID,
                slug: entry.slug,
                name: entry.name,
                description: entry.description,
                imageType: entry.imageType,
                arch: entry.arch,
                version: entry.version,
                downloadUrl: entry.downloadUrl,
                sizeBytes: entry.sizeBytes,
                sha256: entry.sha256,
                sha512: entry.sha512,
            )
            try img.insert(db)
        }
    }

    private nonisolated func syncTemplates(
        db: GRDB.Database, repositoryID: String, catalog: RepoCatalog,
    ) throws {
        guard let templates = catalog.templates else { return }

        try VMTemplate.filter(Column("repositoryId") == repositoryID).deleteAll(db)

        let encoder = JSONEncoder()
        for entry in templates {
            let template = try VMTemplate(
                id: UUID().uuidString,
                slug: entry.slug,
                name: entry.name,
                description: entry.description,
                category: entry.category,
                icon: entry.icon,
                imageSlug: entry.imageSlug,
                cpuCount: entry.cpuCount,
                memoryMB: entry.memoryMB,
                diskSizeGB: entry.diskSizeGB,
                portForwards: String(data: encoder.encode(entry.portForwards), encoding: .utf8),
                networkMode: entry.networkMode ?? "nat",
                inputs: String(data: encoder.encode(entry.inputs), encoding: .utf8) ?? "[]",
                userDataTemplate: entry.userDataTemplate,
                isBuiltIn: true,
                repositoryId: repositoryID,
                createdAt: iso8601.string(from: Date()),
                updatedAt: iso8601.string(from: Date()),
            )
            if var existing =
                try VMTemplate
                    .filter(Column("repositoryId") == repositoryID)
                    .filter(Column("slug") == entry.slug)
                    .fetchOne(db) {
                existing.name = template.name
                existing.description = template.description
                existing.category = template.category
                existing.icon = template.icon
                existing.imageSlug = template.imageSlug
                existing.cpuCount = template.cpuCount
                existing.memoryMB = template.memoryMB
                existing.diskSizeGB = template.diskSizeGB
                existing.portForwards = template.portForwards
                existing.inputs = template.inputs
                existing.userDataTemplate = template.userDataTemplate
                existing.repositoryId = repositoryID
                existing.updatedAt = iso8601.string(from: Date())
                try existing.update(db)
            } else {
                try template.insert(db)
            }
        }
    }
}
