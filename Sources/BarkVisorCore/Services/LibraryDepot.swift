import Foundation
import GRDB

/// Agent-plane Library depot (PAS-176 slice B).
///
/// Bytes move on 7778 (`GET /api/agent/library/images/{id}/content`), never
/// through the 10 MiB Home proxy and never as a LAN URL in the public
/// downloader (SSRF).
public enum LibraryDepotHTTP {
    public static let listPath = "/api/agent/library/images"
    public static let sha256Header = "X-BarkVisor-Image-Sha256"
    public static let sourceUrlHeader = "X-BarkVisor-Image-Source-Url"
    public static let filenameHeader = "X-BarkVisor-Image-Filename"
    public static let imageIdHeader = "X-BarkVisor-Image-Id"
    public static let archHeader = "X-BarkVisor-Image-Arch"
    public static let nameHeader = "X-BarkVisor-Image-Name"

    public static func contentPath(id: String) -> String {
        "/api/agent/library/images/\(id)/content"
    }

    public static func isImageBytesPath(_ path: String) -> Bool {
        path.hasPrefix("/api/agent/library/") && path.hasSuffix("/content")
    }

    /// Percent-encode `sourceUrl` so `&` / `=` in signed CDN URLs survive `req.query`.
    public static func sourceUrlQuery(_ sourceUrl: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        let encoded = sourceUrl.addingPercentEncoding(withAllowedCharacters: allowed) ?? sourceUrl
        return "sourceUrl=\(encoded)"
    }
}

/// Ready Library row a depot Device will advertise over mTLS.
public struct LibraryDepotImageInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var imageType: String
    public var arch: String
    public var status: String
    public var sizeBytes: Int64?
    public var sourceUrl: String?
    public var sha256: String?
    public var slug: String?
    public var filename: String?

    public init(
        id: String,
        name: String,
        imageType: String,
        arch: String,
        status: String,
        sizeBytes: Int64?,
        sourceUrl: String?,
        sha256: String?,
        slug: String?,
        filename: String?,
    ) {
        self.id = id
        self.name = name
        self.imageType = imageType
        self.arch = arch
        self.status = status
        self.sizeBytes = sizeBytes
        self.sourceUrl = sourceUrl
        self.sha256 = sha256
        self.slug = slug
        self.filename = filename
    }
}

public struct LibraryDepotFile: Sendable {
    public var image: VMImage
    public var url: URL
    public var info: LibraryDepotImageInfo
}

/// Local SQLite listing used by the agent-plane Library routes.
public enum LibraryDepotCatalog {
    public static func list(db: Database, sourceUrl: String? = nil) throws -> [LibraryDepotImageInfo] {
        var request = VMImage.filter(Column("status") == "ready")
        if let sourceUrl, !sourceUrl.isEmpty {
            request = request.filter(Column("sourceUrl") == sourceUrl)
        }
        let rows = try request.fetchAll(db)
        return try rows.compactMap { image in
            try describe(image, db: db)
        }
    }

    public static func readyFile(db: Database, id: String) throws -> LibraryDepotFile {
        guard let image = try VMImage.fetchOne(db, key: id) else {
            throw BarkVisorError.notFound("Library image not found")
        }
        guard image.status == "ready" else {
            throw BarkVisorError.notFound("Library image is not ready")
        }
        guard let info = try describe(image, db: db) else {
            throw BarkVisorError.notFound("Library image file is missing")
        }
        return LibraryDepotFile(
            image: image,
            url: URL(fileURLWithPath: image.path ?? ""),
            info: info,
        )
    }

    private static func describe(_ image: VMImage, db: Database) throws -> LibraryDepotImageInfo? {
        guard let path = image.path, !path.isEmpty,
              FileManager.default.fileExists(atPath: path)
        else {
            return nil
        }
        let slug: String? = if let source = image.sourceUrl, !source.isEmpty {
            try RepositoryImage.filter(Column("downloadUrl") == source).fetchOne(db)?.slug
        } else {
            nil
        }
        return LibraryDepotImageInfo(
            id: image.id,
            name: image.name,
            imageType: image.imageType,
            arch: image.arch,
            status: image.status,
            sizeBytes: image.sizeBytes,
            sourceUrl: image.sourceUrl,
            sha256: image.sha256,
            slug: slug,
            filename: URL(fileURLWithPath: path).lastPathComponent,
        )
    }
}

/// Bytes copied from a depot Device. Distinct from ``ImageDownloader``.
public protocol LibraryDepotClient: Sendable {
    func listImages(sourceUrl: String) async throws -> [LibraryDepotImageInfo]
    func fetchBytes(imageId: String, to destination: URL) async throws -> LibraryDepotFetchBytes
}

public struct LibraryDepotFetchBytes: Sendable {
    public var sha256: String
    public var bytesWritten: Int64
    public var filename: String?
    public var reportedSha256: String?

    public init(
        sha256: String,
        bytesWritten: Int64,
        filename: String? = nil,
        reportedSha256: String? = nil,
    ) {
        self.sha256 = sha256
        self.bytesWritten = bytesWritten
        self.filename = filename
        self.reportedSha256 = reportedSha256
    }
}

public struct LibraryDepotFetchRequest: Sendable {
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
}

public protocol LibraryDepotFetching: Sendable {
    func fetchMatching(_ request: LibraryDepotFetchRequest, db: DatabasePool) async -> VMImage?
}
