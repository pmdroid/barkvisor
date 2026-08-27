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
/// downloading row. A `downloading` row with no live copy worker (process
/// restart) is marked failed so callers can fall back to the internet path.
/// Local Workload start does not call this.
public struct LibraryDepotAcquire: LibraryDepotFetching {
    public var localHostId: String
    public var dataDir: URL
    public var devices: DeviceRegistry
    public var openClient: @Sendable (DeviceRecord) throws -> any LibraryDepotClient
    /// When true, `fetchMatching` waits for the byte copy so tests can observe
    /// the terminal row. Production leaves this false.
    public var awaitCopy: Bool
    public var progress: (any ImageProgressPublishing)?
    public var internetFallback: (any ImageDownloadStarting)?

    public init(
        localHostId: String,
        dataDir: URL,
        devices: DeviceRegistry,
        openClient: @escaping @Sendable (DeviceRecord) throws -> any LibraryDepotClient,
        awaitCopy: Bool = false,
        progress: (any ImageProgressPublishing)? = nil,
        internetFallback: (any ImageDownloadStarting)? = nil,
    ) {
        self.localHostId = localHostId
        self.dataDir = dataDir
        self.devices = devices
        self.openClient = openClient
        self.awaitCopy = awaitCopy
        self.progress = progress
        self.internetFallback = internetFallback
    }

    public func fetchMatching(_ request: LibraryDepotFetchRequest, db: DatabasePool) async -> VMImage? {
        let depotHostId = try? await db.read { db in
            try LibrarySettings.resolvedDepotHostId(
                from: db, devices: devices, localHostId: localHostId,
            )
        }
        guard let depotHostId, depotHostId != localHostId else {
            return nil
        }
        switch await LibraryAcquire.resolveLocal(request: request, kind: .depot, db: db) {
        case let .ready(image), let .inFlight(image):
            return image
        case .sourceFailed:
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "previous depot fetch failed; using internet",
            )
            return nil
        case .started, nil:
            break
        }
        guard let client = await client(for: depotHostId, sourceUrl: request.sourceUrl, db: db) else {
            return nil
        }
        guard let remote = await lookup(request, client: client, db: db) else {
            return nil
        }
        let claim: LibraryAcquire.Claim
        do {
            claim = try await LibraryAcquire.claim(request: request, kind: .depot, db: db)
        } catch {
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "could not record depot image: \(error.localizedDescription)",
            )
            return nil
        }
        switch claim {
        case let .ready(image), let .inFlight(image):
            return image
        case .sourceFailed:
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
        _ request: LibraryDepotFetchRequest,
        client: any LibraryDepotClient,
        db: DatabasePool,
    ) async -> LibraryDepotImageInfo? {
        let sha256: String? = if request.sourceUrl.isEmpty, case let .sha256(hash) = request.expectedChecksum {
            hash
        } else {
            nil
        }
        do {
            let listed = try await client.listImages(sourceUrl: request.sourceUrl, sha256: sha256)
            if let match = listed.first(where: { $0.status == "ready" }) {
                return match
            }
            await fallback(db: db, sourceUrl: request.sourceUrl, reason: "depot has no matching image")
            return nil
        } catch {
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "depot unreachable: \(error.localizedDescription)",
            )
            return nil
        }
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
        defer { LibraryAcquire.endLive(job.imageId) }
        await emitProgress(
            ImageProgressEvent(
                id: job.imageId, status: "downloading",
                bytesReceived: 0, totalBytes: job.remote.sizeBytes,
                percent: 0, error: nil,
            ),
        )
        do {
            let updated = try await LibraryAcquire.finish(
                imageId: job.imageId,
                source: DepotLibrarySource(client: client, remoteImageId: job.remote.id),
                request: job.request,
                kind: .depot,
                filename: job.remote.filename,
                db: db,
            )
            await AuditService.logSystem(
                action: "library.depot.fetch",
                detail: "copied \(job.request.sourceUrl) from Device \(job.depotHostId)",
                db: db,
            )
            Log.images.info(
                "Library depot fetch ready for \(job.request.sourceUrl) from Device \(job.depotHostId)",
            )
            let size = updated.sizeBytes ?? 0
            await emitProgress(
                ImageProgressEvent(
                    id: job.imageId, status: "ready",
                    bytesReceived: size, totalBytes: size,
                    percent: 100, error: nil,
                ),
            )
        } catch {
            if await startInternetFallback(job, db: db) {
                await fallback(
                    db: db, sourceUrl: job.request.sourceUrl,
                    reason: "depot fetch failed; using internet: \(error.localizedDescription)",
                )
                return
            }
            await LibraryAcquire.markFailed(
                imageId: job.imageId,
                message: error.localizedDescription,
                kind: .depot,
                db: db,
            )
            await emitProgress(
                ImageProgressEvent(
                    id: job.imageId, status: "error",
                    bytesReceived: 0, totalBytes: nil,
                    percent: nil, error: error.localizedDescription,
                ),
            )
            await fallback(
                db: db, sourceUrl: job.request.sourceUrl,
                reason: "depot fetch failed: \(error.localizedDescription)",
            )
        }
    }

    private func startInternetFallback(_ job: CopyJob, db: DatabasePool) async -> Bool {
        guard let starter = internetFallback,
              let url = URL(string: job.request.sourceUrl)
        else {
            return false
        }
        let destination: URL
        do {
            destination = try await LibraryAcquire.destination(
                imageId: job.imageId,
                sourceUrl: job.request.sourceUrl,
                imageType: job.request.imageType,
                db: db,
            )
            try await db.write { db in
                try db.execute(
                    sql: """
                    UPDATE images SET status = 'downloading', error = NULL, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [iso8601.string(from: Date()), job.imageId],
                )
            }
        } catch {
            return false
        }
        let storedSha: String? = if ImageService.isCompressedSource(job.request.sourceUrl) {
            nil
        } else if case let .sha256(hash) = job.request.expectedChecksum {
            hash
        } else {
            nil
        }
        await starter.start(
            imageID: job.imageId,
            url: url,
            destination: destination,
            expectedChecksum: job.request.expectedChecksum,
            expectedStoredSha256: storedSha,
        )
        return true
    }

    private func emitProgress(_ event: ImageProgressEvent) async {
        await progress?.publish(event)
    }

    private func readyImage(id: String, db: DatabasePool) async -> VMImage? {
        let image = try? await db.read { db in
            try VMImage.fetchOne(db, key: id)
        }
        guard let image, image.status == "ready" else { return nil }
        return image
    }

    static let depotCopyingMarker = LibraryAcquire.depotCopyingMarker

    static func isDepotCopyFailure(_ message: String?) -> Bool {
        LibraryAcquire.isDepotCopyFailure(message)
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
