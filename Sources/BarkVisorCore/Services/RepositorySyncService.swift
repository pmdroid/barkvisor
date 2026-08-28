import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
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
    public let architectures: [String]?
    public let imageByArch: [String: String]?
    public let minMemoryMB: Int?
    public let requiredFeatures: [String]?

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
        architectures: [String]? = nil,
        imageByArch: [String: String]? = nil,
        minMemoryMB: Int? = nil,
        requiredFeatures: [String]? = nil,
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
        self.architectures = architectures
        self.imageByArch = imageByArch
        self.minMemoryMB = minMemoryMB
        self.requiredFeatures = requiredFeatures
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
            try await applyCatalog(catalog, repositoryID: repositoryID, repoName: repo.name)
        } catch {
            await rememberFailure(error, repositoryID: repositoryID)
            throw error
        }
    }

    func syncCatalogData(_ data: Data, repositoryID: String) async throws {
        let repo = try await dbPool.read { db in
            try ImageRepository.fetchOne(db, key: repositoryID)
        }
        guard let repo else { throw BarkVisorError.repositoryNotFound(repositoryID) }

        do {
            let catalog = try RepositoryCatalogDecoder.decode(data, repoName: repo.name)
            try await applyCatalog(catalog, repositoryID: repositoryID, repoName: repo.name)
        } catch {
            await rememberFailure(error, repositoryID: repositoryID)
            throw error
        }
    }

    private func applyCatalog(_ catalog: RepoCatalog, repositoryID: String, repoName: String) async throws {
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
            "Synced repository '\(repoName)': \(catalog.images.count) images, \(templateCount) templates",
        )
    }

    private func rememberFailure(_ error: Error, repositoryID: String) async {
        let now = iso8601.string(from: Date())
        try? await dbPool.write { db in
            try db.execute(
                sql: "UPDATE image_repositories SET lastError = ?, updatedAt = ? WHERE id = ?",
                arguments: [error.localizedDescription, now, repositoryID],
            )
        }
    }

    private func fetchCatalog(repo: ImageRepository) async throws -> RepoCatalog {
        guard let url = URL(string: repo.url) else {
            throw BarkVisorError.repositorySyncFailed("Invalid URL: \(repo.url)")
        }

        // SSRF protection: validate URL does not target private/internal hosts.
        // This check runs at sync time (not just repo creation) to defend against
        // DNS rebinding where a hostname's resolution changes after initial validation.
        if let ssrfError = SSRFGuard.fetchRejection(for: url) {
            throw BarkVisorError.repositorySyncFailed(ssrfError)
        }

        let maxCatalogSize = 10 * 1_024 * 1_024
        // Do not use URLSession.shared: it follows redirects without
        // re-running SSRFGuard.validate / pinEndpoint.
        let (data, response) = try await SSRFGuard.defaultSession.data(from: url)
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

        return try RepositoryCatalogDecoder.decode(data, repoName: repo.name)
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
                architecturesJson: JSONColumnCoding.encodeArrayOrNil(entry.architectures),
                minMemoryMB: entry.minMemoryMB,
                requiredFeaturesJson: JSONColumnCoding.encodeArrayOrNil(entry.requiredFeatures),
                imageByArchJson: JSONColumnCoding.encode(entry.imageByArch),
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
                existing.architecturesJson = template.architecturesJson
                existing.minMemoryMB = template.minMemoryMB
                existing.requiredFeaturesJson = template.requiredFeaturesJson
                existing.imageByArchJson = template.imageByArchJson
                try existing.update(db)
            } else {
                try template.insert(db)
            }
        }
    }
}

enum RepositoryCatalogDecoder {
    static func decode(_ data: Data, repoName: String) throws -> RepoCatalog {
        do {
            return try JSONDecoder().decode(RepoCatalog.self, from: data)
        } catch let repoError {
            do {
                let templateCatalog = try JSONDecoder().decode(TemplateCatalog.self, from: data)
                return mapTemplateCatalog(templateCatalog, repoName: repoName)
            } catch let templateError {
                logDecodeFailure(repoError: repoError, templateError: templateError)
                throw BarkVisorError.repositorySyncFailed(
                    lastErrorMessage(repoError: repoError, templateError: templateError, data: data),
                )
            }
        }
    }

    private static func mapTemplateCatalog(_ catalog: TemplateCatalog, repoName: String) -> RepoCatalog {
        RepoCatalog(
            name: repoName,
            version: catalog.version,
            images: [],
            templates: catalog.templates.map { entry in
                RepoCatalogTemplate(
                    slug: entry.slug, name: entry.name, description: entry.description,
                    category: entry.category, icon: entry.icon, imageSlug: entry.imageSlug,
                    cpuCount: entry.cpuCount, memoryMB: entry.memoryMB, diskSizeGB: entry.diskSizeGB,
                    portForwards: entry.portForwards, networkMode: entry.networkMode,
                    inputs: entry.inputs, userDataTemplate: entry.userDataTemplate,
                    architectures: entry.architectures, imageByArch: entry.imageByArch,
                    minMemoryMB: entry.minMemoryMB, requiredFeatures: entry.requiredFeatures,
                )
            },
        )
    }

    private static func logDecodeFailure(repoError: Error, templateError: Error) {
        Log.sync.error("RepoCatalog decode failed: \(String(describing: repoError))")
        Log.sync.error("TemplateCatalog decode failed: \(String(describing: templateError))")
    }

    private static func lastErrorMessage(repoError: Error, templateError: Error, data: Data) -> String {
        let chosen = preferredError(repoError: repoError, templateError: templateError)
        if let decoding = chosen as? DecodingError {
            return format(decoding, data: data)
        }
        return chosen.localizedDescription
    }

    private static func preferredError(repoError: Error, templateError: Error) -> Error {
        let repoPath = codingPathLength(repoError)
        let templatePath = codingPathLength(templateError)
        if templatePath >= repoPath {
            return templateError
        }
        return repoError
    }

    private static func codingPathLength(_ error: Error) -> Int {
        guard let decoding = error as? DecodingError else { return -1 }
        return formatPath(decoding).split(separator: ".").count
    }

    private static func format(_ error: DecodingError, data: Data) -> String {
        let path = formatPath(error)
        let slug = templateSlug(data: data, codingPath: context(error).codingPath)
        var message = "Catalog decode failed at \(path)"
        if let slug {
            message += " (template slug: \(slug))"
        }
        message += ": \(detail(error))"
        return message
    }

    private static func formatPath(_ error: DecodingError) -> String {
        var keys = context(error).codingPath
        if case let .keyNotFound(key, _) = error {
            keys.append(key)
        }
        let parts = keys.map { key -> String in
            if let index = key.intValue {
                return String(index)
            }
            let raw = key.stringValue
            if raw.hasPrefix("Index "), let index = Int(raw.dropFirst(6)) {
                return String(index)
            }
            return raw
        }
        return parts.isEmpty ? "(root)" : parts.joined(separator: ".")
    }

    private static func detail(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, _):
            return "missing key '\(key.stringValue)'"
        case let .typeMismatch(type, context):
            return "type mismatch (\(type)) \(context.debugDescription)"
        case let .valueNotFound(type, context):
            return "value not found (\(type)) \(context.debugDescription)"
        case let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }

    private static func context(_ error: DecodingError) -> DecodingError.Context {
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .keyNotFound(_, context):
            return context
        case let .dataCorrupted(context):
            return context
        @unknown default:
            return DecodingError.Context(codingPath: [], debugDescription: String(describing: error))
        }
    }

    private static func templateSlug(data: Data, codingPath: [CodingKey]) -> String? {
        var sawTemplates = false
        var index: Int?
        for key in codingPath {
            if key.stringValue == "templates" {
                sawTemplates = true
                continue
            }
            if sawTemplates {
                if let value = key.intValue {
                    index = value
                } else if key.stringValue.hasPrefix("Index "),
                          let value = Int(key.stringValue.dropFirst(6)) {
                    index = value
                }
                break
            }
        }
        guard let index,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let templates = root["templates"] as? [[String: Any]],
              templates.indices.contains(index)
        else { return nil }
        return templates[index]["slug"] as? String
    }
}
