import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import GRDB

public struct LibraryFetchRequest: Sendable {
    public var sourceUrl: String
    public var name: String
    public var imageType: String
    public var arch: String
    public var expectedChecksum: ExpectedChecksum?

    public init(
        sourceUrl: String,
        name: String,
        imageType: String,
        arch: String,
        expectedChecksum: ExpectedChecksum?,
    ) {
        self.sourceUrl = sourceUrl
        self.name = name
        self.imageType = imageType
        self.arch = arch
        self.expectedChecksum = expectedChecksum
    }

    public init(repoImage: RepositoryImage) {
        self.init(
            sourceUrl: repoImage.downloadUrl,
            name: repoImage.name,
            imageType: repoImage.imageType,
            arch: repoImage.arch,
            expectedChecksum: .catalog(from: repoImage),
        )
    }
}

public enum LibraryAcquire {
    public enum Claim: Sendable {
        case ready(VMImage)
        case inFlight(VMImage)
        case started(VMImage)
        case sourceFailed

        var imageId: String {
            switch self {
            case let .ready(image), let .inFlight(image), let .started(image):
                image.id
            case .sourceFailed:
                ""
            }
        }
    }

    public static func resolveLocal(
        request: LibraryFetchRequest,
        db: DatabasePool,
    ) async -> Claim? {
        do {
            return try await db.write { db in
                try decide(request: request, insertIfMissing: false, db: db)
            }
        } catch {
            return nil
        }
    }

    public static func claim(
        request: LibraryFetchRequest,
        db: DatabasePool,
    ) async throws -> Claim {
        try await db.write { db in
            try decide(request: request, insertIfMissing: true, db: db)
                ?? .sourceFailed
        }
    }

    public static func destination(
        imageId: String,
        sourceUrl: String,
        imageType: String,
        filename: String? = nil,
        db: DatabasePool,
    ) async throws -> URL {
        let imagesDir = try await db.read { try Config.imagesDir(from: $0) }
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let name = filename
            ?? URL(string: sourceUrl)?.lastPathComponent
            ?? "image"
        let ext = ImageService.imageExtension(from: name, imageType: imageType)
        return imagesDir.appendingPathComponent("\(imageId).\(ext)")
    }

    public static func verify(
        destination: URL,
        request: LibraryFetchRequest,
        fetched: LibraryFetchedBytes,
    ) throws {
        guard let expected = request.expectedChecksum else { return }
        try ImageFileChecksum.verify(
            ofFile: destination,
            expected: expected,
            knownSha256: fetched.sha256,
        )
    }

    @discardableResult
    public static func persistReady(
        imageId: String,
        path: String,
        sizeBytes: Int64,
        sha256: String,
        db: DatabasePool,
    ) async throws -> VMImage? {
        let now = iso8601.string(from: Date())
        return try await db.write { db -> VMImage? in
            guard var row = try VMImage.fetchOne(db, key: imageId) else { return nil }
            row.path = path
            row.sizeBytes = sizeBytes
            row.status = "ready"
            row.error = nil
            row.sha256 = sha256
            row.updatedAt = now
            try row.update(db)
            return row
        }
    }

    public static func markFailed(
        imageId: String,
        message: String,
        db: DatabasePool,
    ) async {
        try? await db.write { db in
            try db.execute(
                sql: "UPDATE images SET status = 'error', error = ?, updatedAt = ? WHERE id = ?",
                arguments: [message, iso8601.string(from: Date()), imageId],
            )
        }
    }

    public static func finish(
        imageId: String,
        source: any LibraryByteSource,
        request: LibraryFetchRequest,
        filename: String? = nil,
        db: DatabasePool,
    ) async throws -> VMImage {
        let destination = try await destination(
            imageId: imageId,
            sourceUrl: request.sourceUrl,
            imageType: request.imageType,
            filename: filename,
            db: db,
        )
        do {
            let fetched = try await source.copyBytes(to: destination)
            try verify(
                destination: destination,
                request: request,
                fetched: fetched,
            )
            let sizeBytes =
                (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64)
                    ?? fetched.bytesWritten
            guard let row = try await persistReady(
                imageId: imageId,
                path: destination.path,
                sizeBytes: sizeBytes,
                sha256: fetched.sha256,
                db: db,
            ) else {
                throw BarkVisorError.downloadFailed("could not record image: row missing")
            }
            return row
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func decide(
        request: LibraryFetchRequest,
        insertIfMissing: Bool,
        db: Database,
    ) throws -> Claim? {
        let key = claimSourceUrl(request)
        var rows = try VMImage.filter(Column("sourceUrl") == key).fetchAll(db)
        if rows.isEmpty, request.sourceUrl.isEmpty, case let .sha256(hash) = request.expectedChecksum {
            let want = hash.lowercased()
            rows = try VMImage.fetchAll(db).filter { $0.sha256?.lowercased() == want }
        }
        if let ready = rows.first(where: {
            $0.status == "ready"
                && ImageService.matchesCatalogChecksum($0, expected: request.expectedChecksum)
        }) {
            return .ready(ready)
        }
        if let downloading = rows.first(where: { $0.status == "downloading" }) {
            return .inFlight(downloading)
        }
        guard insertIfMissing else { return nil }
        let now = iso8601.string(from: Date())
        let image = VMImage(
            id: UUID().uuidString,
            name: request.name,
            imageType: request.imageType,
            arch: request.arch,
            path: nil,
            sizeBytes: nil,
            status: "downloading",
            error: nil,
            sourceUrl: key,
            createdAt: now,
            updatedAt: now,
        )
        try image.insert(db)
        return .started(image)
    }

    private static func claimSourceUrl(_ request: LibraryFetchRequest) -> String {
        if !request.sourceUrl.isEmpty { return request.sourceUrl }
        if case let .sha256(hash) = request.expectedChecksum {
            return "sha256:" + hash.lowercased()
        }
        return request.sourceUrl
    }
}

public struct LibraryFetchedBytes: Sendable {
    public var sha256: String
    public var bytesWritten: Int64
    public var reportedSha256: String?

    public init(sha256: String, bytesWritten: Int64, reportedSha256: String? = nil) {
        self.sha256 = sha256
        self.bytesWritten = bytesWritten
        self.reportedSha256 = reportedSha256
    }
}

public protocol LibraryByteSource: Sendable {
    func copyBytes(to destination: URL) async throws -> LibraryFetchedBytes
}

public struct InternetLibrarySource: LibraryByteSource {
    public var url: URL
    public var session: URLSession

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func copyBytes(to destination: URL) async throws -> LibraryFetchedBytes {
        let (tempURL, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw BarkVisorError.downloadFailed("HTTP \(http.statusCode) from \(url)")
        }
        let parent = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        let size =
            (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64)
                ?? 0
        let sha = try ImageFileChecksum.sha256Hex(ofFile: destination)
        return LibraryFetchedBytes(sha256: sha, bytesWritten: size)
    }
}
