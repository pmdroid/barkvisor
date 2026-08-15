import Foundation
import GRDB

/// Copy a ready depot image into this Device's Library on a local miss.
///
/// Lookup is awaited (small JSON GET). Byte copy runs in the background and
/// the caller receives a `downloading` row so proxied deploys stay inside
/// the Home 10s timeout. Failures before the copy starts return `nil` so
/// deploy/download keeps today's internet path (PAS-47 / PAS-90). A failed
/// copy tags the Library row so a later `fetchMatching` also returns `nil`
/// instead of listing the depot again. Concurrent callers share one
/// downloading row. Local Workload start does not call this.
public struct LibraryDepotAcquire: LibraryDepotFetching {
    public var localHostId: String
    public var dataDir: URL
    public var devices: DeviceRegistry
    public var openClient: @Sendable (DeviceRecord) throws -> any LibraryDepotClient
    /// When true, `fetchMatching` waits for the byte copy so tests can observe
    /// the terminal row. Production leaves this false.
    public var awaitCopy: Bool

    public init(
        localHostId: String,
        dataDir: URL,
        devices: DeviceRegistry,
        openClient: @escaping @Sendable (DeviceRecord) throws -> any LibraryDepotClient,
        awaitCopy: Bool = false,
    ) {
        self.localHostId = localHostId
        self.dataDir = dataDir
        self.devices = devices
        self.openClient = openClient
        self.awaitCopy = awaitCopy
    }

    public func fetchMatching(_ request: LibraryDepotFetchRequest, db: DatabasePool) async -> VMImage? {
        guard let depotHostId = try? await db.read({ try LibrarySettings.resolvedDepotHostId(from: $0) }),
              depotHostId != localHostId
        else {
            return nil
        }
        if await hasDepotCopyFailure(sourceUrl: request.sourceUrl, db: db) {
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "previous depot fetch failed; using internet",
            )
            return nil
        }
        guard let client = await client(for: depotHostId, sourceUrl: request.sourceUrl, db: db) else {
            return nil
        }
        guard let remote = await lookup(request.sourceUrl, client: client, db: db) else {
            return nil
        }
        switch await claimDownload(request: request, db: db) {
        case let .ready(image), let .inFlight(image):
            return image
        case .depotFailed:
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "previous depot fetch failed; using internet",
            )
            return nil
        case let .started(pending):
            let job = CopyJob(
                remote: remote, request: request, imageId: pending.id, depotHostId: depotHostId,
            )
            let work: @Sendable () async -> Void = {
                await self.copyRemote(job, client: client, db: db)
            }
            if awaitCopy {
                await work()
                return await readyImage(id: pending.id, db: db)
            }
            Task.detached { await work() }
            return pending
        case nil:
            return nil
        }
    }

    private func client(
        for depotHostId: String,
        sourceUrl: String,
        db: DatabasePool,
    ) async -> (any LibraryDepotClient)? {
        let record: DeviceRecord
        do {
            guard let found = try devices.record(forHostId: depotHostId) else {
                await fallback(db: db, sourceUrl: sourceUrl, reason: "depot Device is not paired")
                return nil
            }
            record = found
        } catch {
            await fallback(
                db: db, sourceUrl: sourceUrl,
                reason: "Device registry is unavailable; using internet",
            )
            return nil
        }
        guard let agentHost = record.agentHost, !agentHost.isEmpty else {
            await fallback(db: db, sourceUrl: sourceUrl, reason: "depot Device has no reachable address")
            return nil
        }
        do {
            return try openClient(record)
        } catch {
            await fallback(
                db: db, sourceUrl: sourceUrl,
                reason: "depot client failed: \(error.localizedDescription)",
            )
            return nil
        }
    }

    private func lookup(
        _ sourceUrl: String,
        client: any LibraryDepotClient,
        db: DatabasePool,
    ) async -> LibraryDepotImageInfo? {
        do {
            let listed = try await client.listImages(sourceUrl: sourceUrl)
            if let match = listed.first(where: { $0.status == "ready" }) {
                return match
            }
            await fallback(db: db, sourceUrl: sourceUrl, reason: "depot has no matching image")
            return nil
        } catch {
            await fallback(
                db: db, sourceUrl: sourceUrl,
                reason: "depot unreachable: \(error.localizedDescription)",
            )
            return nil
        }
    }

    private enum DownloadClaim {
        case ready(VMImage)
        case inFlight(VMImage)
        case started(VMImage)
        case depotFailed
    }

    /// Insert or reuse the Library row for this catalog URL in one write so
    /// concurrent download/deploy requests share a single depot copy.
    private func claimDownload(request: LibraryDepotFetchRequest, db: DatabasePool) async -> DownloadClaim? {
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
            sourceUrl: request.sourceUrl,
            createdAt: now,
            updatedAt: now,
        )
        do {
            return try await db.write { db in
                let rows = try VMImage
                    .filter(Column("sourceUrl") == request.sourceUrl)
                    .fetchAll(db)
                if let ready = rows.first(where: { $0.status == "ready" }) {
                    return .ready(ready)
                }
                if let downloading = rows.first(where: { $0.status == "downloading" }) {
                    return .inFlight(downloading)
                }
                if rows.contains(where: { $0.status == "error" && Self.isDepotCopyFailure($0.error) }) {
                    return .depotFailed
                }
                try image.insert(db)
                return .started(image)
            }
        } catch {
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "could not record depot image: \(error.localizedDescription)",
            )
            return nil
        }
    }

    private func hasDepotCopyFailure(sourceUrl: String, db: DatabasePool) async -> Bool {
        let rows = try? await db.read { db in
            try VMImage.filter(Column("sourceUrl") == sourceUrl).fetchAll(db)
        }
        guard let rows else { return false }
        if rows.contains(where: { $0.status == "ready" || $0.status == "downloading" }) {
            return false
        }
        return rows.contains { $0.status == "error" && Self.isDepotCopyFailure($0.error) }
    }

    private struct CopyJob {
        var remote: LibraryDepotImageInfo
        var request: LibraryDepotFetchRequest
        var imageId: String
        var depotHostId: String
    }

    private func copyRemote(
        _ job: CopyJob,
        client: any LibraryDepotClient,
        db: DatabasePool,
    ) async {
        let destination: URL
        do {
            let imagesDir = try await db.read { try Config.imagesDir(from: $0) }
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            let filename = job.remote.filename
                ?? URL(string: job.request.sourceUrl)?.lastPathComponent
                ?? "image"
            let ext = ImageService.imageExtension(from: filename, imageType: job.request.imageType)
            destination = imagesDir.appendingPathComponent("\(job.imageId).\(ext)")
        } catch {
            await markFailed(imageId: job.imageId, db: db, message: error.localizedDescription)
            await fallback(
                db: db, sourceUrl: job.request.sourceUrl,
                reason: "Library directory unavailable: \(error.localizedDescription)",
            )
            return
        }

        let fetched: LibraryDepotFetchBytes
        do {
            fetched = try await client.fetchBytes(imageId: job.remote.id, to: destination)
            try verify(
                destination: destination,
                sourceUrl: job.request.sourceUrl,
                computedSha256: fetched.sha256,
                remoteSha256: fetched.reportedSha256 ?? job.remote.sha256,
                expectedChecksum: job.request.expectedChecksum,
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            await markFailed(imageId: job.imageId, db: db, message: error.localizedDescription)
            await fallback(
                db: db, sourceUrl: job.request.sourceUrl,
                reason: "depot fetch failed: \(error.localizedDescription)",
            )
            return
        }

        await persist(job, destination: destination, fetched: fetched, db: db)
    }

    private func persist(
        _ job: CopyJob,
        destination: URL,
        fetched: LibraryDepotFetchBytes,
        db: DatabasePool,
    ) async {
        let now = iso8601.string(from: Date())
        let sizeBytes =
            (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64)
                ?? fetched.bytesWritten
        do {
            let updated = try await db.write { db -> VMImage? in
                guard var row = try VMImage.fetchOne(db, key: job.imageId) else { return nil }
                row.path = destination.path
                row.sizeBytes = sizeBytes
                row.status = "ready"
                row.error = nil
                row.sha256 = fetched.sha256
                row.updatedAt = now
                try row.update(db)
                return row
            }
            guard updated != nil else {
                try? FileManager.default.removeItem(at: destination)
                await fallback(
                    db: db, sourceUrl: job.request.sourceUrl,
                    reason: "could not record depot image: row missing",
                )
                return
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            await markFailed(imageId: job.imageId, db: db, message: error.localizedDescription)
            await fallback(
                db: db, sourceUrl: job.request.sourceUrl,
                reason: "could not record depot image: \(error.localizedDescription)",
            )
            return
        }
        await AuditService.logSystem(
            action: "library.depot.fetch",
            detail: "copied \(job.request.sourceUrl) from Device \(job.depotHostId)",
            db: db,
        )
        Log.images.info(
            "Library depot fetch ready for \(job.request.sourceUrl) from Device \(job.depotHostId)",
        )
    }

    private func verify(
        destination: URL,
        sourceUrl: String,
        computedSha256: String,
        remoteSha256: String?,
        expectedChecksum: ExpectedChecksum?,
    ) throws {
        if let remoteSha256, !remoteSha256.isEmpty,
           computedSha256.lowercased() != remoteSha256.lowercased() {
            throw BarkVisorError.downloadFailed(
                "SHA256 mismatch: expected \(remoteSha256.lowercased()), got \(computedSha256)",
            )
        }
        // Depot stores the decompressed file; catalog hashes are of the compressed
        // artifact. Compare the stored-file digest only for .xz/.gz/.zst/.bz2 sources.
        guard let expectedChecksum, !ImageService.isCompressedSource(sourceUrl) else { return }
        switch expectedChecksum {
        case let .sha256(hash):
            let expected = hash.lowercased()
            guard computedSha256.lowercased() == expected else {
                throw BarkVisorError.downloadFailed(
                    "SHA256 mismatch: expected \(expected), got \(computedSha256)",
                )
            }
        case let .sha512(hash):
            let computed = try ImageFileChecksum.sha512Hex(ofFile: destination)
            let expected = hash.lowercased()
            guard computed.lowercased() == expected else {
                throw BarkVisorError.downloadFailed(
                    "SHA512 mismatch: expected \(expected), got \(computed)",
                )
            }
        }
    }

    private func readyImage(id: String, db: DatabasePool) async -> VMImage? {
        let image = try? await db.read { db in
            try VMImage.fetchOne(db, key: id)
        }
        guard let image, image.status == "ready" else { return nil }
        return image
    }

    /// Prefix so a later `fetchMatching` can tell a depot copy failure from
    /// an internet / upload error and skip the depot on retry.
    private static let depotFailurePrefix = "Library depot: "

    static func isDepotCopyFailure(_ message: String?) -> Bool {
        message?.hasPrefix(depotFailurePrefix) == true
    }

    private func markFailed(imageId: String, db: DatabasePool, message: String) async {
        let tagged = message.hasPrefix(Self.depotFailurePrefix)
            ? message
            : Self.depotFailurePrefix + message
        try? await db.write { db in
            try db.execute(
                sql: "UPDATE images SET status = 'error', error = ?, updatedAt = ? WHERE id = ?",
                arguments: [tagged, iso8601.string(from: Date()), imageId],
            )
        }
    }

    private func fallback(db: DatabasePool, sourceUrl: String, reason: String) async {
        await AuditService.logSystem(
            action: "library.depot.fallback",
            detail: "\(reason) (\(sourceUrl))",
            db: db,
        )
        Log.images.warning("Library depot fallback: \(reason)")
    }
}
