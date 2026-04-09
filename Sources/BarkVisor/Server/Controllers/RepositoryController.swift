import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct CreateRepositoryRequest: Content {
    let url: String
    let repoType: String // "images" or "templates"
}

struct RepositoryResponse: Content {
    let id: String
    let name: String
    let url: String
    let isBuiltIn: Bool
    let repoType: String
    let lastSyncedAt: String?
    let lastError: String?
    let syncStatus: String
    let createdAt: String
    let updatedAt: String

    init(from repo: ImageRepository) {
        self.id = repo.id
        self.name = repo.name
        self.url = repo.url
        self.isBuiltIn = repo.isBuiltIn
        self.repoType = repo.repoType
        self.lastSyncedAt = repo.lastSyncedAt
        self.lastError = repo.lastError
        self.syncStatus = repo.syncStatus
        self.createdAt = repo.createdAt
        self.updatedAt = repo.updatedAt
    }
}

struct RepositoryImageResponse: Content {
    let id: String
    let repositoryId: String
    let slug: String
    let name: String
    let description: String?
    let imageType: String
    let arch: String
    let version: String?
    let downloadUrl: String
    let sizeBytes: Int64?

    init(from img: RepositoryImage) {
        self.id = img.id
        self.repositoryId = img.repositoryId
        self.slug = img.slug
        self.name = img.name
        self.description = img.description
        self.imageType = img.imageType
        self.arch = img.arch
        self.version = img.version
        self.downloadUrl = img.downloadUrl
        self.sizeBytes = img.sizeBytes
    }
}

struct RepositoryController: RouteCollection {
    let syncService: RepositorySyncService
    let imageDownloader: ImageDownloader
    let backgroundTasks: BackgroundTaskManager

    func boot(routes: any RoutesBuilder) throws {
        let repos = routes.grouped("api", "repositories")
        repos.get(use: list)
        repos.post(use: create)
        repos.delete(":id", use: delete)
        repos.post(":id", "sync", use: sync)
        repos.get(":id", "images", use: images)
        repos.post("images", ":repoImageId", "download", use: downloadImage)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [RepositoryResponse] {
        let (limit, offset) = req.pagination()
        let repos = try await req.db.read { db in
            try ImageRepository.limit(limit, offset: offset).fetchAll(db)
        }
        return repos.map { RepositoryResponse(from: $0) }
    }

    @Sendable
    func create(req: Vapor.Request) async throws -> RepositoryResponse {
        let body = try req.content.decode(CreateRepositoryRequest.self)

        guard let url = URL(string: body.url),
              let scheme = url.scheme?.lowercased(),
              Config.allowedURLSchemes.contains(scheme)
        else {
            throw Abort(.badRequest, reason: "Invalid URL. Only http:// and https:// URLs are allowed.")
        }

        // Block requests to private/internal IP ranges (SSRF protection)
        guard let host = url.host?.lowercased() else {
            throw Abort(.badRequest, reason: "URL must contain a valid host")
        }
        if SSRFGuard.isPrivateHost(host) {
            throw Abort(
                .badRequest, reason: "URLs pointing to private or internal addresses are not allowed",
            )
        }

        guard body.repoType == "images" || body.repoType == "templates" else {
            throw Abort(.badRequest, reason: "repoType must be 'images' or 'templates'")
        }

        let now = iso8601.string(from: Date())
        let id = UUID().uuidString

        // Fetch the catalog to get the name
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw Abort(.badRequest, reason: "Failed to fetch repository catalog")
        }

        // Validate the catalog can be parsed
        let catalogName: String
        if let catalog = try? JSONDecoder().decode(RepoCatalog.self, from: data) {
            catalogName = catalog.name
        } else if (try? JSONDecoder().decode(TemplateCatalog.self, from: data)) != nil {
            catalogName = "Templates"
        } else {
            throw Abort(.badRequest, reason: "Invalid catalog format")
        }

        let repo = ImageRepository(
            id: id, name: catalogName, url: body.url,
            isBuiltIn: false, repoType: body.repoType,
            lastSyncedAt: nil, lastError: nil,
            syncStatus: "idle", createdAt: now, updatedAt: now,
        )

        try await req.db.write { db in
            try repo.insert(db)
        }

        // Trigger sync in background via task manager
        let syncService = syncService
        let pool = req.db
        await backgroundTasks.submit("repo-sync:\(id)", kind: .repoSync) { @Sendable in
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE image_repositories SET syncStatus = 'syncing', updatedAt = ? WHERE id = ?",
                    arguments: [iso8601.string(from: Date()), id],
                )
            }
            try await syncService.sync(repositoryID: id)
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE image_repositories SET syncStatus = 'idle', updatedAt = ? WHERE id = ?",
                    arguments: [iso8601.string(from: Date()), id],
                )
            }
            return nil
        }

        return RepositoryResponse(from: repo)
    }

    @Sendable
    func delete(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }

        let repo = try await req.db.read { db in
            try ImageRepository.fetchOne(db, key: id)
        }
        guard let repo else { throw Abort(.notFound) }

        if repo.isBuiltIn {
            throw Abort(.forbidden, reason: "Cannot delete built-in repository")
        }

        _ = try await req.db.write { db in
            try ImageRepository.deleteOne(db, key: id)
        }
        return .noContent
    }

    @Sendable
    func sync(req: Vapor.Request) async throws -> Response {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }

        guard let repo = try await req.db.read({ db in
            try ImageRepository.fetchOne(db, key: id)
        })
        else {
            throw Abort(.notFound)
        }

        // Prevent concurrent syncs for the same repository
        if repo.syncStatus == "syncing" {
            throw Abort(.conflict, reason: "Repository is already syncing")
        }

        let taskID = "repo-sync:\(id)"
        let syncService = syncService
        let pool = req.db
        await backgroundTasks.submit(taskID, kind: .repoSync) { @Sendable in
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE image_repositories SET syncStatus = 'syncing', updatedAt = ? WHERE id = ?",
                    arguments: [iso8601.string(from: Date()), id],
                )
            }
            do {
                try await syncService.sync(repositoryID: id)
                try await pool.write { db in
                    try db.execute(
                        sql: "UPDATE image_repositories SET syncStatus = 'idle', updatedAt = ? WHERE id = ?",
                        arguments: [iso8601.string(from: Date()), id],
                    )
                }
            } catch {
                Log.sync.error("Repository sync failed for \(id): \(error)")
                do {
                    try await pool.write { db in
                        try db.execute(
                            sql:
                            "UPDATE image_repositories SET syncStatus = 'error', lastError = ?, updatedAt = ? WHERE id = ?",
                            arguments: [error.localizedDescription, iso8601.string(from: Date()), id],
                        )
                    }
                } catch {
                    Log.sync.error("Failed to update sync error status for repo \(id): \(error)")
                }
                throw error
            }
            return nil
        }

        let response = TaskAcceptedResponse(taskID: taskID)
        let data = try JSONEncoder().encode(response)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .accepted, headers: headers, body: .init(data: data))
    }

    @Sendable
    func images(req: Vapor.Request) async throws -> [RepositoryImageResponse] {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }

        let imgs = try await req.db.read { db in
            try RepositoryImage.filter(Column("repositoryId") == id).fetchAll(db)
        }
        return imgs.map { RepositoryImageResponse(from: $0) }
    }

    @Sendable
    func downloadImage(req: Vapor.Request) async throws -> Response {
        guard let repoImageId = req.parameters.get("repoImageId") else {
            throw Abort(.badRequest)
        }

        let repoImage = try await req.db.read { db in
            try RepositoryImage.fetchOne(db, key: repoImageId)
        }
        guard let repoImage else { throw Abort(.notFound) }

        guard let sourceURL = URL(string: repoImage.downloadUrl),
              let scheme = sourceURL.scheme?.lowercased(),
              Config.allowedURLSchemes.contains(scheme)
        else {
            throw Abort(.badRequest, reason: "Invalid download URL")
        }
        if let host = sourceURL.host?.lowercased(), SSRFGuard.isPrivateHost(host) {
            throw Abort(
                .badRequest, reason: "Download URLs pointing to private addresses are not allowed",
            )
        }

        let now = iso8601.string(from: Date())
        let imageId = UUID().uuidString
        // Handle compound extensions like .qcow2.xz — keep full suffix for download,
        // decompression in ImageDownloader will strip the compression extension
        let filename = sourceURL.lastPathComponent
        let ext: String
        if filename.hasSuffix(".qcow2.xz") || filename.hasSuffix(".img.xz")
            || filename.hasSuffix(".img.gz") || filename.hasSuffix(".qcow2.gz") {
            // Keep compound extension so decompression produces the right file
            let parts = filename.split(separator: ".", maxSplits: 1)
            ext = parts.count > 1 ? String(parts[1]) : (repoImage.imageType == "iso" ? "iso" : "img")
        } else {
            ext =
                sourceURL.pathExtension.isEmpty
                    ? (repoImage.imageType == "iso" ? "iso" : "img")
                    : sourceURL.pathExtension
        }
        let destination = Config.dataDir.appendingPathComponent("images/\(imageId).\(ext)")

        let image = VMImage(
            id: imageId, name: repoImage.name, imageType: repoImage.imageType,
            arch: repoImage.arch, path: nil, sizeBytes: nil,
            status: "downloading", error: nil, sourceUrl: repoImage.downloadUrl,
            createdAt: now, updatedAt: now,
        )

        try await req.db.write { db in
            try image.insert(db)
        }

        let checksum: ExpectedChecksum? =
            if let sha256 = repoImage.sha256, !sha256.isEmpty {
                .sha256(sha256)
            } else if let sha512 = repoImage.sha512, !sha512.isEmpty {
                .sha512(sha512)
            } else {
                nil
            }

        await imageDownloader.start(
            imageID: imageId, url: sourceURL, destination: destination, expectedChecksum: checksum,
        )

        let encoder = JSONEncoder()
        let responseData = try encoder.encode(ImageResponse(from: image))
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .ok, headers: headers, body: .init(data: responseData))
    }
}
