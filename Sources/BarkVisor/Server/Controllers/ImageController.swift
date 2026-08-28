import BarkVisorCore
import Foundation
import GRDB
import Vapor

// MARK: - Request/Response DTOs

struct ImageResponse: Content {
    let id: String
    let name: String
    let imageType: String
    let arch: String
    let status: String
    let sizeBytes: Int64?
    let sourceUrl: String?
    let error: String?
    let sha256: String?
    let createdAt: String
    let updatedAt: String
    let path: String?
    /// Live 0...100 while transferring. Nil when total size is unknown or idle.
    let downloadPercent: Int?

    init(from image: VMImage, downloadPercent: Int? = nil) {
        self.id = image.id
        self.name = image.name
        self.imageType = image.imageType
        self.arch = image.arch
        self.status = image.status
        self.sizeBytes = image.sizeBytes
        self.sourceUrl = image.sourceUrl
        self.error = image.error
        self.sha256 = image.sha256
        self.createdAt = image.createdAt
        self.updatedAt = image.updatedAt
        self.path = image.path
        self.downloadPercent = downloadPercent
    }
}

struct DownloadImageRequest: Content, Validatable {
    let name: String
    let url: String
    let imageType: String
    let arch: String

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1 ... 255))
        validations.add("url", as: String.self, is: !.empty)
        validations.add("imageType", as: String.self, is: .in("iso", "cloud-image"))
        validations.add("arch", as: String.self, is: .in("arm64", "x86_64"))
    }
}

struct AcquireImageRequest: Content, Validatable {
    let name: String
    let imageType: String
    let arch: String
    let sourceUrl: String?
    let sha256: String?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1 ... 255))
        validations.add("imageType", as: String.self, is: .in("iso", "cloud-image"))
        validations.add("arch", as: String.self, is: .in("arm64", "x86_64"))
    }
}

// MARK: - Image Controller

struct ImageController: RouteCollection {
    let downloader: ImageDownloader

    func boot(routes: any RoutesBuilder) throws {
        let images = routes.grouped("api", "images")
        images.get(use: list)
        images.get(":id", use: get)
        images.delete(":id", use: delete)
        images.post("download", use: startDownload)
        images.post("acquire", use: acquire)
        images.get(":id", "progress", use: progress)

        // Tus endpoints (PATCH receives 50 MB chunks)
        images.on(.POST, "tus", use: tusCreate)
        images.on(.HEAD, "tus", ":uploadId", use: tusHead)
        images.on(.PATCH, "tus", ":uploadId", body: .collect(maxSize: "50mb"), use: tusPatch)
        images.on(.DELETE, "tus", ":uploadId", use: tusDelete)

        // Tus OPTIONS for discovery
        images.on(.OPTIONS, "tus", use: tusOptions)
    }

    // MARK: - CRUD

    @Sendable
    func list(req: Vapor.Request) async throws -> [ImageResponse] {
        let (limit, offset) = req.pagination()
        let images = try await req.db.read { db in
            try VMImage.limit(limit, offset: offset).fetchAll(db)
        }
        return await responses(images)
    }

    @Sendable
    func get(req: Vapor.Request) async throws -> ImageResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }
        guard let image = try await req.db.read({ db in
            try VMImage.fetchOne(db, key: id)
        })
        else {
            throw Abort(.notFound)
        }
        return await response(image)
    }

    @Sendable
    func delete(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }
        try await ImageService.delete(id: id, downloader: downloader, db: req.db)
        return .noContent
    }

    // MARK: - URL Download

    @Sendable
    func startDownload(req: Vapor.Request) async throws -> ImageResponse {
        try DownloadImageRequest.validate(content: req)
        let body = try req.content.decode(DownloadImageRequest.self)

        // SSRF: scheme allowlist + SSRFGuard.validate (hostname and DNS).
        if let reason = Self.downloadURLRejection(body.url) {
            throw Abort(.badRequest, reason: reason)
        }

        let image = try await ImageService.startDownload(
            ImageDownloadRequest(name: body.name, url: body.url, imageType: body.imageType, arch: body.arch),
            downloader: downloader, db: req.db,
        )
        return await response(image)
    }

    @Sendable
    func acquire(req: Vapor.Request) async throws -> ImageResponse {
        try AcquireImageRequest.validate(content: req)
        let body = try req.content.decode(AcquireImageRequest.self)
        let source = body.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sha = body.sha256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if source.isEmpty && sha.isEmpty {
            throw Abort(.badRequest, reason: "sourceUrl or sha256 is required")
        }
        if !source.isEmpty, let reason = Self.downloadURLRejection(source) {
            throw Abort(.badRequest, reason: reason)
        }
        let checksum: ExpectedChecksum? = sha.isEmpty ? nil : .sha256(sha)
        if !source.isEmpty {
            if let existing = try await req.db.read({ db in
                try ImageService.readyImage(
                    sourceUrl: source, expectedChecksum: checksum, db: db,
                )
            }) {
                return await response(existing)
            }
        } else if let existing = try await req.db.read({ db in
            try ImageService.readyImage(sha256: sha, db: db)
        }) {
            return await response(existing)
        }
        if source.isEmpty {
            throw Abort(.badRequest, reason: "Image cannot be copied without a source URL")
        }
        let storedSha: String? = if sha.isEmpty || ImageService.isCompressedSource(source) {
            nil
        } else {
            sha
        }
        let image = try await ImageService.startDownload(
            ImageDownloadRequest(
                name: body.name,
                url: source,
                imageType: body.imageType,
                arch: body.arch,
                expectedChecksum: checksum,
                expectedStoredSha256: storedSha,
            ),
            downloader: downloader, db: req.db,
        )
        return await response(image)
    }

    // MARK: - SSE Progress

    @Sendable
    func progress(req: Vapor.Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }

        guard try await req.db.read({ db in
            try VMImage.fetchOne(db, key: id)
        }) != nil
        else {
            throw Abort(.notFound)
        }

        let stream = await downloader.progressStream(imageID: id)
        return SSEResponse.stream(from: stream, keepaliveSeconds: 15)
    }

    private func responses(_ images: [VMImage]) async -> [ImageResponse] {
        var result: [ImageResponse] = []
        result.reserveCapacity(images.count)
        for image in images {
            await result.append(response(image))
        }
        return result
    }

    private func response(_ image: VMImage) async -> ImageResponse {
        await ImageResponse(from: image, downloadPercent: downloadPercent(for: image))
    }

    private func downloadPercent(for image: VMImage) async -> Int? {
        await ImageTransferPercent.current(
            status: image.status,
            lastProgress: downloader.lastProgress(imageID: image.id),
        )
    }

    // MARK: - Tus Protocol

    private func tusHeaders() -> HTTPHeaders {
        HTTPHeaders([
            ("Tus-Resumable", "1.0.0"),
            ("Tus-Version", "1.0.0"),
            ("Tus-Max-Size", "137438953472"),
            ("Tus-Extension", "creation,termination"),
        ])
    }

    @Sendable
    func tusOptions(req: Vapor.Request) async throws -> Response {
        var headers = tusHeaders()
        headers.add(name: .contentLength, value: "0")
        return Response(status: .noContent, headers: headers)
    }

    @Sendable
    func tusCreate(req: Vapor.Request) async throws -> Response {
        guard let lengthStr = req.headers.first(name: "Upload-Length"),
              let length = Int64(lengthStr)
        else {
            throw Abort(.badRequest, reason: "Missing or invalid Upload-Length header")
        }

        let metadataRaw = req.headers.first(name: "Upload-Metadata") ?? ""
        let metadata = ImageService.parseTusMetadata(metadataRaw)

        guard let name = metadata["name"],
              let imageType = metadata["imageType"],
              let arch = metadata["arch"]
        else {
            throw Abort(.badRequest, reason: "Upload-Metadata must include name, imageType, arch")
        }

        guard ["iso", "cloud-image"].contains(imageType) else {
            throw Abort(.badRequest, reason: "imageType must be 'iso' or 'cloud-image'")
        }
        guard ["arm64", "x86_64"].contains(arch) else {
            throw Abort(.badRequest, reason: "arch must be 'arm64' or 'x86_64'")
        }

        let now = iso8601.string(from: Date())
        let imageId = UUID().uuidString
        let uploadId = UUID().uuidString
        let chunkPath = Config.dataDir.appendingPathComponent("tus-uploads/\(uploadId).part")

        FileManager.default.createFile(atPath: chunkPath.path, contents: nil)

        let image = VMImage(
            id: imageId, name: name, imageType: imageType, arch: arch,
            path: nil, sizeBytes: nil, status: "uploading", error: nil,
            sourceUrl: nil, createdAt: now, updatedAt: now,
        )

        let upload = TusUpload(
            id: uploadId, imageId: imageId, offset: 0, length: length,
            metadata: metadataRaw, chunkPath: chunkPath.path,
            createdAt: now, updatedAt: now,
        )

        try await req.db.write { db in
            try image.insert(db)
            try upload.insert(db)
        }

        var headers = tusHeaders()
        headers.add(name: "Location", value: "/api/images/tus/\(uploadId)")
        headers.add(name: .contentLength, value: "0")

        return Response(status: .created, headers: headers)
    }

    @Sendable
    func tusHead(req: Vapor.Request) async throws -> Response {
        guard let uploadId = req.parameters.get("uploadId") else {
            throw Abort(.badRequest)
        }

        guard let upload = try await req.db.read({ db in
            try TusUpload.fetchOne(db, key: uploadId)
        })
        else {
            throw Abort(.notFound)
        }

        var headers = tusHeaders()
        headers.add(name: "Upload-Offset", value: "\(upload.offset)")
        headers.add(name: "Upload-Length", value: "\(upload.length)")
        headers.add(name: .contentLength, value: "0")
        headers.add(name: "Cache-Control", value: "no-store")

        return Response(status: .ok, headers: headers)
    }

    @Sendable
    func tusPatch(req: Vapor.Request) async throws -> Response {
        guard let uploadId = req.parameters.get("uploadId") else {
            throw Abort(.badRequest)
        }

        guard req.headers.contentType?.serialize() == "application/offset+octet-stream" else {
            throw Abort(
                .unsupportedMediaType, reason: "Content-Type must be application/offset+octet-stream",
            )
        }

        guard let clientOffsetStr = req.headers.first(name: "Upload-Offset"),
              let clientOffset = Int64(clientOffsetStr)
        else {
            throw Abort(.badRequest, reason: "Missing or invalid Upload-Offset header")
        }

        let upload = try await req.db.read { db in
            try TusUpload.fetchOne(db, key: uploadId)
        }
        guard var upload else {
            throw Abort(.notFound)
        }

        guard clientOffset == upload.offset else {
            throw Abort(
                .conflict, reason: "Upload-Offset mismatch: expected \(upload.offset), got \(clientOffset)",
            )
        }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: upload.chunkPath))
        defer { try? handle.close() }
        try handle.seekToEnd()

        guard let bodyData = req.body.data else {
            throw Abort(.badRequest, reason: "Empty body")
        }

        let bytes = Data(buffer: bodyData)
        try handle.write(contentsOf: bytes)

        let bytesWritten = Int64(bytes.count)
        upload.offset += bytesWritten
        upload.updatedAt = iso8601.string(from: Date())

        let isComplete = upload.offset >= upload.length

        let uploadToSave = upload
        try await req.db.write { db in
            try uploadToSave.update(db)
        }

        if isComplete {
            try await ImageService.finalizeTusUpload(upload: upload, db: req.db)
        }

        var headers = tusHeaders()
        headers.add(name: "Upload-Offset", value: "\(upload.offset)")
        headers.add(name: .contentLength, value: "0")

        return Response(status: .noContent, headers: headers)
    }

    @Sendable
    func tusDelete(req: Vapor.Request) async throws -> Response {
        guard let uploadId = req.parameters.get("uploadId") else {
            throw Abort(.badRequest)
        }

        guard let upload = try await req.db.read({ db in
            try TusUpload.fetchOne(db, key: uploadId)
        })
        else {
            throw Abort(.notFound)
        }

        try? FileManager.default.removeItem(atPath: upload.chunkPath)

        try await req.db.write { db in
            try db.execute(
                sql:
                "UPDATE images SET status = 'error', error = 'Upload cancelled', updatedAt = ? WHERE id = ?",
                arguments: [iso8601.string(from: Date()), upload.imageId],
            )
            _ = try TusUpload.deleteOne(db, key: uploadId)
        }

        var headers = tusHeaders()
        headers.add(name: .contentLength, value: "0")
        return Response(status: .noContent, headers: headers)
    }

    /// Classifier for POST /api/images/download. Scheme + ``SSRFGuard.validate(url:)``.
    static func downloadURLRejection(_ urlString: String) -> String? {
        guard let parsedURL = URL(string: urlString),
              let scheme = parsedURL.scheme?.lowercased(),
              Config.allowedURLSchemes.contains(scheme)
        else {
            return "Invalid URL. Only http:// and https:// URLs are allowed."
        }
        if let ssrfError = SSRFGuard.validate(url: parsedURL) {
            return ssrfError
        }
        return nil
    }
}
