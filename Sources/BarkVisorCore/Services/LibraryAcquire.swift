import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import GRDB

/// Catalog reference → local Library row. Depot and internet are byte-source adapters.
public enum LibraryAcquire {
    public enum Kind: Sendable, Equatable {
        case internet
        case depot
    }

    public enum Claim: Sendable {
        case ready(VMImage)
        case inFlight(VMImage)
        case started(VMImage)
        case sourceFailed
    }

    /// Prefix so a later acquire can tell a depot copy failure from an internet error.
    public static let depotFailurePrefix = "Library depot: "
    /// In-progress marker on a depot downloading row so restart can reclaim it.
    public static let depotCopyingMarker = depotFailurePrefix + "copying"

    public static func isDepotCopyFailure(_ message: String?) -> Bool {
        message?.hasPrefix(depotFailurePrefix) == true
            && message != depotCopyingMarker
    }

    /// Local ready / in-flight / failed row. Reclaims a dead depot copy.
    public static func resolveLocal(
        request: LibraryDepotFetchRequest,
        kind: Kind,
        db: DatabasePool,
    ) async -> Claim? {
        do {
            return try await db.write { db in
                try decide(request: request, kind: kind, insertIfMissing: false, db: db)
            }
        } catch {
            return nil
        }
    }

    /// Insert or reuse the Library row for this catalog URL in one write.
    public static func claim(
        request: LibraryDepotFetchRequest,
        kind: Kind,
        db: DatabasePool,
    ) async throws -> Claim {
        try await db.write { db in
            try decide(request: request, kind: kind, insertIfMissing: true, db: db)
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
        kind: Kind,
        request: LibraryDepotFetchRequest,
        fetched: LibraryFetchedBytes,
    ) throws {
        if kind == .depot, let reported = fetched.reportedSha256, !reported.isEmpty,
           fetched.sha256.lowercased() != reported.lowercased() {
            throw BarkVisorError.downloadFailed(
                "SHA256 mismatch: expected \(reported.lowercased()), got \(fetched.sha256)",
            )
        }
        guard let expected = request.expectedChecksum else { return }
        if kind == .depot, ImageService.isCompressedSource(request.sourceUrl) { return }
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
        kind: Kind,
        db: DatabasePool,
    ) async {
        let tagged: String =
            if kind == .depot {
                message.hasPrefix(depotFailurePrefix) ? message : depotFailurePrefix + message
            } else {
                message
            }
        try? await db.write { db in
            try db.execute(
                sql: "UPDATE images SET status = 'error', error = ?, updatedAt = ? WHERE id = ?",
                arguments: [tagged, iso8601.string(from: Date()), imageId],
            )
        }
    }

    /// Fetch → verify → persist. Both adapters use this path.
    public static func finish(
        imageId: String,
        source: any LibraryByteSource,
        request: LibraryDepotFetchRequest,
        kind: Kind,
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
                kind: kind,
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

    public static func beginLive(_ id: String) {
        LiveLibraryJobs.begin(id)
    }

    public static func endLive(_ id: String) {
        LiveLibraryJobs.end(id)
    }

    public static func hasLive(_ id: String) -> Bool {
        LiveLibraryJobs.contains(id)
    }

    private static func isDepotCopy(_ image: VMImage) -> Bool {
        image.error?.hasPrefix(depotFailurePrefix) == true
    }

    private static func markInterrupted(_ imageId: String, db: Database) throws {
        try db.execute(
            sql: "UPDATE images SET status = 'error', error = ?, updatedAt = ? WHERE id = ?",
            arguments: [
                depotFailurePrefix + "copy interrupted",
                iso8601.string(from: Date()),
                imageId,
            ],
        )
    }

    private static func decide(
        request: LibraryDepotFetchRequest,
        kind: Kind,
        insertIfMissing: Bool,
        db: Database,
    ) throws -> Claim? {
        let rows = try VMImage.filter(Column("sourceUrl") == request.sourceUrl).fetchAll(db)
        if let ready = rows.first(where: {
            $0.status == "ready"
                && ImageService.matchesCatalogChecksum($0, expected: request.expectedChecksum)
        }) {
            return .ready(ready)
        }
        if let downloading = rows.first(where: { $0.status == "downloading" }) {
            if kind == .depot, isDepotCopy(downloading), !LiveLibraryJobs.contains(downloading.id) {
                try markInterrupted(downloading.id, db: db)
                return .sourceFailed
            }
            return .inFlight(downloading)
        }
        if kind == .depot,
           rows.contains(where: { $0.status == "error" && isDepotCopyFailure($0.error) }) {
            return .sourceFailed
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
            error: kind == .depot ? depotCopyingMarker : nil,
            sourceUrl: request.sourceUrl,
            createdAt: now,
            updatedAt: now,
        )
        try image.insert(db)
        if kind == .depot {
            LiveLibraryJobs.begin(image.id)
        }
        return .started(image)
    }
}

/// Bytes already on disk after an adapter copy. sha256 is of those bytes.
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

/// Copy catalog bytes onto this Device. Depot and internet implement this.
public protocol LibraryByteSource: Sendable {
    func copyBytes(to destination: URL) async throws -> LibraryFetchedBytes
}

/// Adapter: another Device's Library over the agent plane.
public struct DepotLibrarySource: LibraryByteSource {
    public var client: any LibraryDepotClient
    public var remoteImageId: String

    public init(client: any LibraryDepotClient, remoteImageId: String) {
        self.client = client
        self.remoteImageId = remoteImageId
    }

    public func copyBytes(to destination: URL) async throws -> LibraryFetchedBytes {
        let fetched = try await client.fetchBytes(imageId: remoteImageId, to: destination)
        return LibraryFetchedBytes(
            sha256: fetched.sha256,
            bytesWritten: fetched.bytesWritten,
            reportedSha256: fetched.reportedSha256,
        )
    }
}

/// Adapter: public catalog URL.
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

/// Process-lifetime in-flight depot copies. Empty after restart so orphans fall back.
private enum LiveLibraryJobs {
    private static let shared = LiveLibraryJobSet()

    static func begin(_ id: String) {
        shared.begin(id)
    }

    static func end(_ id: String) {
        shared.end(id)
    }

    static func contains(_ id: String) -> Bool {
        shared.contains(id)
    }
}

private final class LiveLibraryJobSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()

    func begin(_ id: String) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func end(_ id: String) {
        lock.lock()
        ids.remove(id)
        lock.unlock()
    }

    func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}
