import Foundation
import GRDB

public enum CatalogDownloadClaim: Sendable {
    case existing(VMImage)
    case started(VMImage)

    public var image: VMImage {
        switch self {
        case let .existing(image), let .started(image):
            image
        }
    }
}

public struct ImageDownloadRequest: Sendable {
    public let name: String
    public let url: String
    public let imageType: String
    public let arch: String

    public init(name: String, url: String, imageType: String, arch: String) {
        self.name = name
        self.url = url
        self.imageType = imageType
        self.arch = arch
    }
}

public enum ImageService {
    /// Delete an image: remove file, cancel downloads, clean up tus uploads, delete DB record.
    public static func delete(id: String, downloader: ImageDownloader, db: DatabasePool) async throws {
        let image = try await db.read { db in
            try VMImage.fetchOne(db, key: id)
        }
        guard let image else {
            throw BarkVisorError.notFound()
        }

        // Delete file from disk if it exists
        if let path = image.path {
            try? FileManager.default.removeItem(atPath: path)
        }

        // Cancel any active download
        await downloader.cancel(imageID: id)

        // Delete any tus uploads for this image
        let tusUploads = try await db.read { db in
            try TusUpload.filter(Column("imageId") == id).fetchAll(db)
        }
        for upload in tusUploads {
            try? FileManager.default.removeItem(atPath: upload.chunkPath)
        }

        // Delete from DB (cascade deletes tus_uploads)
        _ = try await db.write { db in
            try VMImage.deleteOne(db, key: id)
        }
    }

    /// Start downloading an image from a URL.
    public static func startDownload(
        _ request: ImageDownloadRequest,
        downloader: ImageDownloader,
        db: DatabasePool,
    ) async throws -> VMImage {
        guard ["iso", "cloud-image"].contains(request.imageType) else {
            throw BarkVisorError.badRequest("imageType must be 'iso' or 'cloud-image'")
        }
        guard request.arch == "arm64" || request.arch == "x86_64" else {
            throw BarkVisorError.badRequest("arch must be 'arm64' or 'x86_64'")
        }
        guard let sourceURL = URL(string: request.url) else {
            throw BarkVisorError.badRequest("Invalid URL")
        }

        let now = iso8601.string(from: Date())
        let id = UUID().uuidString

        let ext = Self.imageExtension(from: sourceURL.lastPathComponent, imageType: request.imageType)
        let filename = "\(id).\(ext)"
        let imagesDir = try await db.read { try Config.imagesDir(from: $0) }
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let destination = imagesDir.appendingPathComponent(filename)

        let image = VMImage(
            id: id, name: request.name, imageType: request.imageType, arch: request.arch,
            path: nil, sizeBytes: nil, status: "downloading", error: nil,
            sourceUrl: request.url, createdAt: now, updatedAt: now,
        )

        try await db.write { db in
            try image.insert(db)
        }

        await downloader.start(imageID: id, url: sourceURL, destination: destination)

        return image
    }

    /// Ready Library row for `sourceUrl` whose stored digest still matches the catalog.
    public static func readyImage(
        sourceUrl: String,
        expectedChecksum: ExpectedChecksum?,
        db: Database,
    ) throws -> VMImage? {
        let rows = try VMImage
            .filter(Column("sourceUrl") == sourceUrl)
            .filter(Column("status") == "ready")
            .fetchAll(db)
        for row in rows where matchesCatalogChecksum(row, expected: expectedChecksum) {
            return row
        }
        return nil
    }

    /// Catalog hashes are of the compressed artifact; stored `sha256` is the
    /// decompressed file. For compressed sources, verify the recorded digest
    /// against the on-disk file instead of comparing to the catalog hash.
    public static func matchesCatalogChecksum(
        _ image: VMImage,
        expected: ExpectedChecksum?,
    ) -> Bool {
        guard let expected else { return true }
        if let source = image.sourceUrl, isCompressedSource(source) {
            return matchesRecordedDigest(image)
        }
        switch expected {
        case let .sha256(hash):
            let want = hash.lowercased()
            if let stored = image.sha256, !stored.isEmpty {
                return stored.lowercased() == want
            }
            guard let path = image.path, FileManager.default.fileExists(atPath: path) else {
                return false
            }
            let computed = try? ImageFileChecksum.sha256Hex(ofFile: URL(fileURLWithPath: path))
            return computed?.lowercased() == want
        case let .sha512(hash):
            guard let path = image.path, FileManager.default.fileExists(atPath: path) else {
                return false
            }
            let computed = try? ImageFileChecksum.sha512Hex(ofFile: URL(fileURLWithPath: path))
            return computed?.lowercased() == hash.lowercased()
        }
    }

    /// Insert a downloading Library row or reuse one already in flight for this
    /// catalog URL. The ready/downloading check and insert run in one write so
    /// concurrent catalog downloads share a single internet fetch.
    public static func startOrDetectCatalogDownload(
        repoImage: RepositoryImage,
        sourceURL: URL,
        checksum: ExpectedChecksum?,
        downloader: any ImageDownloadStarting,
        db: DatabasePool,
    ) async throws -> CatalogDownloadClaim {
        let request = LibraryDepotFetchRequest(
            sourceUrl: repoImage.downloadUrl,
            name: repoImage.name,
            imageType: repoImage.imageType,
            arch: repoImage.arch,
            expectedChecksum: checksum,
        )
        switch try await LibraryAcquire.claim(request: request, kind: .internet, db: db) {
        case let .ready(image), let .inFlight(image):
            return .existing(image)
        case .sourceFailed:
            throw BarkVisorError.downloadFailed("Library row is not usable for this catalog URL")
        case let .started(image):
            let destination = try await LibraryAcquire.destination(
                imageId: image.id,
                sourceUrl: repoImage.downloadUrl,
                imageType: repoImage.imageType,
                db: db,
            )
            await downloader.start(
                imageID: image.id, url: sourceURL, destination: destination, expectedChecksum: checksum,
            )
            return .started(image)
        }
    }

    /// Finalize a completed tus upload: move chunk file to final location, decompress if needed, and update DB.
    public static func finalizeTusUpload(upload: TusUpload, db: DatabasePool) async throws {
        let image = try await db.read { database in
            try VMImage.fetchOne(database, key: upload.imageId)
        }
        guard let image else { return }

        // Determine extension from original filename (TUS metadata) to detect compression
        let metadata = parseTusMetadata(upload.metadata)
        let originalName = metadata["name"] ?? ""
        let ext = imageExtension(from: originalName, imageType: image.imageType)
        let finalName = "\(image.id).\(ext)"
        let imagesDir = try await db.read { try Config.imagesDir(from: $0) }
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let finalPath = imagesDir.appendingPathComponent(finalName)
        let chunkURL = URL(fileURLWithPath: upload.chunkPath)

        do {
            // Move chunk to images directory
            if FileManager.default.fileExists(atPath: finalPath.path) {
                try FileManager.default.removeItem(at: finalPath)
            }
            try FileManager.default.moveItem(at: chunkURL, to: finalPath)

            // Decompress if the file is compressed
            let resolvedPath = try decompressIfNeeded(finalPath)

            // Get file size
            let attrs = try FileManager.default.attributesOfItem(atPath: resolvedPath.path)
            let size = attrs[.size] as? Int64 ?? upload.length
            let digest = try ImageFileChecksum.sha256Hex(ofFile: resolvedPath)

            // Update image to ready
            let now = iso8601.string(from: Date())
            try await db.write { database in
                try database.execute(
                    sql:
                    "UPDATE images SET status = 'ready', error = NULL, path = ?, sizeBytes = ?, sha256 = ?, updatedAt = ? WHERE id = ?",
                    arguments: [resolvedPath.path, size, digest, now, image.id],
                )
                _ = try TusUpload.deleteOne(database, key: upload.id)
            }

            Log.images.info("Upload finalized: \(image.name) (\(size) bytes)")
        } catch {
            try? FileManager.default.removeItem(at: finalPath)
            // Also clean up potential decompressed file
            try? FileManager.default.removeItem(at: finalPath.deletingPathExtension())
            try? FileManager.default.removeItem(atPath: upload.chunkPath)

            let now = iso8601.string(from: Date())
            try? await db.write { database in
                try database.execute(
                    sql: "UPDATE images SET status = 'error', error = ?, updatedAt = ? WHERE id = ?",
                    arguments: [String(describing: error), now, image.id],
                )
                _ = try TusUpload.deleteOne(database, key: upload.id)
            }

            throw error
        }
    }

    /// Parse tus protocol Upload-Metadata header.
    public static func parseTusMetadata(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let pairs = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for pair in pairs {
            let parts = pair.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let decoded = Data(base64Encoded: String(parts[1])),
                  let value = String(data: decoded, encoding: .utf8)
            else {
                continue
            }
            result[String(parts[0])] = value
        }
        return result
    }

    // MARK: - Compression Helpers

    private static let compressionExtensions = [".xz", ".gz", ".zst", ".bz2"]

    /// True when the stored `sha256` still matches the bytes on disk.
    private static func matchesRecordedDigest(_ image: VMImage) -> Bool {
        guard let stored = image.sha256, !stored.isEmpty else { return false }
        guard let path = image.path, FileManager.default.fileExists(atPath: path) else {
            return false
        }
        let computed = try? ImageFileChecksum.sha256Hex(ofFile: URL(fileURLWithPath: path))
        return computed?.lowercased() == stored.lowercased()
    }

    /// Catalog checksums cover the compressed download; the depot stores the decompressed file.
    static func isCompressedSource(_ sourceUrl: String) -> Bool {
        let path = URL(string: sourceUrl)?.path ?? sourceUrl
        let lower = path.lowercased()
        return compressionExtensions.contains { lower.hasSuffix($0) }
    }

    /// Derive the file extension from a filename, preserving compound extensions for compressed files.
    /// e.g. "manjaro.img.xz" → "img.xz", "ubuntu.qcow2.gz" → "qcow2.gz", "debian.iso" → "iso"
    static func imageExtension(from filename: String, imageType: String) -> String {
        let lower = filename.lowercased()
        if let compExt = compressionExtensions.first(where: { lower.hasSuffix($0) }) {
            let withoutComp = String(filename.dropLast(compExt.count))
            let innerExt = (withoutComp as NSString).pathExtension
            if !innerExt.isEmpty {
                return "\(innerExt)\(compExt)"
            }
            // No inner extension — use imageType default + compression
            let defaultExt = imageType == "iso" ? "iso" : "img"
            return "\(defaultExt)\(compExt)"
        }
        let ext = (filename as NSString).pathExtension
        if ext.isEmpty {
            return imageType == "iso" ? "iso" : "img"
        }
        return ext
    }

    /// Decompress a file if it has a known compression extension. Returns the path to the final (decompressed) file.
    static func decompressIfNeeded(_ path: URL) throws -> URL {
        let pathStr = path.path
        guard let compExt = compressionExtensions.first(where: { pathStr.hasSuffix($0) }) else {
            return path
        }

        let decompressed = path.deletingPathExtension()
        let executable: URL
        let arguments: [String]
        switch compExt {
        case ".xz":
            executable = try BundleResolver.helper("xz")
            arguments = ["--decompress", "--keep", pathStr]
        case ".gz":
            executable = try BundleResolver.system("gunzip")
            arguments = ["--keep", pathStr]
        case ".zst":
            executable = try BundleResolver.helper("zstd")
            arguments = ["-d", "--keep", pathStr]
        case ".bz2":
            executable = try BundleResolver.system("bunzip2")
            arguments = ["--keep", pathStr]
        default:
            return path
        }

        let result = try PlatformProcess.run(
            executable: executable, arguments: arguments, timeout: 600,
        )
        guard result.succeeded else {
            throw BarkVisorError.decompressFailed(
                "Decompression failed (exit \(result.exitCode)): \(result.stderrString)",
            )
        }

        // Remove compressed file, return decompressed path
        try? FileManager.default.removeItem(at: path)
        return decompressed
    }
}
