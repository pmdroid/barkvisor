import Foundation
import GRDB

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
        guard request.arch == "arm64" else {
            throw BarkVisorError.badRequest("arch must be 'arm64'")
        }
        guard let sourceURL = URL(string: request.url) else {
            throw BarkVisorError.badRequest("Invalid URL")
        }

        let now = iso8601.string(from: Date())
        let id = UUID().uuidString

        let ext = Self.imageExtension(from: sourceURL.lastPathComponent, imageType: request.imageType)
        let filename = "\(id).\(ext)"
        let destination = Config.dataDir.appendingPathComponent("images/\(filename)")

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
        let finalPath = Config.dataDir.appendingPathComponent("images/\(finalName)")
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

            // Update image to ready
            let now = iso8601.string(from: Date())
            try await db.write { database in
                try database.execute(
                    sql:
                    "UPDATE images SET status = 'ready', error = NULL, path = ?, sizeBytes = ?, updatedAt = ? WHERE id = ?",
                    arguments: [resolvedPath.path, size, now, image.id],
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
        let process = Process()
        let errPipe = Pipe()
        process.standardError = errPipe

        switch compExt {
        case ".xz":
            process.executableURL = try BundleResolver.helper("xz")
            process.arguments = ["--decompress", "--keep", pathStr]
        case ".gz":
            process.executableURL = try BundleResolver.system("gunzip")
            process.arguments = ["--keep", pathStr]
        case ".zst":
            process.executableURL = try BundleResolver.helper("zstd")
            process.arguments = ["-d", "--keep", pathStr]
        case ".bz2":
            process.executableURL = try BundleResolver.system("bunzip2")
            process.arguments = ["--keep", pathStr]
        default:
            return path
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr =
                String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BarkVisorError.decompressFailed(
                "Decompression failed (exit \(process.terminationStatus)): \(stderr)",
            )
        }

        // Remove compressed file, return decompressed path
        try? FileManager.default.removeItem(at: path)
        return decompressed
    }
}
