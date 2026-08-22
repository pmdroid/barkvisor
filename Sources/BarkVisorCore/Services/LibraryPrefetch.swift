import Foundation
import GRDB

/// Copy a ready Library image from a paired Device onto this Device.
///
/// Bytes move on the agent plane (`GET /api/agent/library/images/{id}/content`).
/// The Home proxy never carries the blob. This is not content-addressed storage:
/// each Device keeps its own file.
public struct LibraryPrefetch: Sendable {
    public var localHostId: String
    public var dataDir: URL
    public var devices: DeviceRegistry
    public var openClient: @Sendable (DeviceRecord) throws -> any LibraryDepotClient
    /// When true, `start` waits for the byte copy so tests can observe the
    /// terminal row. Production leaves this false.
    public var awaitCopy: Bool
    public var progress: (any ImageProgressPublishing)?

    public init(
        localHostId: String,
        dataDir: URL,
        devices: DeviceRegistry,
        openClient: @escaping @Sendable (DeviceRecord) throws -> any LibraryDepotClient,
        awaitCopy: Bool = false,
        progress: (any ImageProgressPublishing)? = nil,
    ) {
        self.localHostId = localHostId
        self.dataDir = dataDir
        self.devices = devices
        self.openClient = openClient
        self.awaitCopy = awaitCopy
        self.progress = progress
    }

    public func start(_ request: ImagePrefetchRequest, db: DatabasePool) async throws -> VMImage {
        guard !request.sourceHostId.isEmpty, !request.sourceImageId.isEmpty else {
            throw BarkVisorError.badRequest("sourceHostId and sourceImageId are required")
        }
        guard ["iso", "cloud-image"].contains(request.imageType) else {
            throw BarkVisorError.badRequest("imageType must be 'iso' or 'cloud-image'")
        }
        guard request.arch == "arm64" || request.arch == "x86_64" else {
            throw BarkVisorError.badRequest("arch must be 'arm64' or 'x86_64'")
        }

        if request.sourceHostId == localHostId {
            guard let image = try await db.read({ db in
                try VMImage.fetchOne(db, key: request.sourceImageId)
            }), image.status == "ready"
            else {
                throw BarkVisorError.notFound("Library image is not ready on this Device")
            }
            return image
        }

        let claim = try await claim(request, db: db)
        switch claim {
        case let .ready(image), let .inFlight(image):
            return image
        case .sourceFailed:
            throw BarkVisorError.downloadFailed("A previous prefetch of this image failed")
        case let .started(pending):
            let client = try await openSourceClient(request.sourceHostId)
            let work: @Sendable () async -> Void = {
                await self.copyRemote(request, imageId: pending.id, client: client, db: db)
            }
            if awaitCopy {
                await work()
                guard let image = try await db.read({ db in
                    try VMImage.fetchOne(db, key: pending.id)
                })
                else {
                    throw BarkVisorError.downloadFailed("could not record prefetched image")
                }
                return image
            }
            Task.detached { await work() }
            return pending
        }
    }

    private func openSourceClient(_ sourceHostId: String) async throws -> any LibraryDepotClient {
        let record: DeviceRecord
        do {
            guard let found = try devices.record(forHostId: sourceHostId) else {
                throw BarkVisorError.notFound("Source Device is not paired")
            }
            record = found
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw BarkVisorError.internalError("Device registry is unavailable")
        }
        guard let host = record.agentHost, !host.isEmpty else {
            throw BarkVisorError.notFound("Source Device has no reachable address")
        }
        do {
            return try openClient(record)
        } catch {
            throw BarkVisorError.downloadFailed(
                "Could not reach source Device: \(error.localizedDescription)",
            )
        }
    }

    private func claim(
        _ request: ImagePrefetchRequest,
        db: DatabasePool,
    ) async throws -> LibraryAcquire.Claim {
        try await db.write { db in
            let sha = request.sha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let sourceUrl = request.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rows = try VMImage.fetchAll(db)

            if !sha.isEmpty,
               let ready = rows.first(where: {
                   $0.status == "ready" && $0.sha256?.lowercased() == sha
               }) {
                return .ready(ready)
            }
            if !sourceUrl.isEmpty,
               let ready = rows.first(where: {
                   $0.status == "ready"
                       && ($0.sourceUrl ?? "") == sourceUrl
                       && ImageService.matchesCatalogChecksum(
                           $0,
                           expected: sha.isEmpty ? nil : .sha256(sha),
                       )
               }) {
                return .ready(ready)
            }

            if let downloading = liveDownload(in: rows, sha: sha, sourceUrl: sourceUrl, request: request) {
                return .inFlight(downloading)
            }

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
                sourceUrl: sourceUrl.isEmpty ? nil : sourceUrl,
                sha256: sha.isEmpty ? nil : sha,
                createdAt: now,
                updatedAt: now,
            )
            try image.insert(db)
            LibraryAcquire.beginLive(image.id)
            return .started(image)
        }
    }

    private func liveDownload(
        in rows: [VMImage],
        sha: String,
        sourceUrl: String,
        request: ImagePrefetchRequest,
    ) -> VMImage? {
        rows.first { image in
            guard image.status == "downloading", LibraryAcquire.hasLive(image.id) else {
                return false
            }
            if !sha.isEmpty, image.sha256?.lowercased() == sha {
                return true
            }
            if !sourceUrl.isEmpty, (image.sourceUrl ?? "") == sourceUrl {
                return true
            }
            return image.name == request.name
                && image.imageType == request.imageType
                && image.arch == request.arch
                && sourceUrl.isEmpty
                && sha.isEmpty
        }
    }

    private func copyRemote(
        _ request: ImagePrefetchRequest,
        imageId: String,
        client: any LibraryDepotClient,
        db: DatabasePool,
    ) async {
        defer { LibraryAcquire.endLive(imageId) }
        let fetchRequest = LibraryDepotFetchRequest(
            sourceUrl: request.sourceUrl ?? "",
            name: request.name,
            imageType: request.imageType,
            arch: request.arch,
            expectedChecksum: request.sha256.flatMap {
                $0.isEmpty ? nil : .sha256($0)
            },
        )
        do {
            let updated = try await LibraryAcquire.finish(
                imageId: imageId,
                source: DepotLibrarySource(client: client, remoteImageId: request.sourceImageId),
                request: fetchRequest,
                kind: .depot,
                db: db,
            )
            await AuditService.logSystem(
                action: "library.prefetch",
                detail: "copied \(request.name) from Device \(request.sourceHostId)",
                db: db,
            )
            Log.images.info(
                "Library prefetch ready for \(request.name) from Device \(request.sourceHostId)",
            )
            let size = updated.sizeBytes ?? 0
            await progress?.publish(
                ImageProgressEvent(
                    id: imageId, status: "ready",
                    bytesReceived: size, totalBytes: size,
                    percent: 100, error: nil,
                ),
            )
        } catch {
            await LibraryAcquire.markFailed(
                imageId: imageId,
                message: error.localizedDescription,
                kind: .internet,
                db: db,
            )
            await progress?.publish(
                ImageProgressEvent(
                    id: imageId, status: "error",
                    bytesReceived: 0, totalBytes: nil,
                    percent: nil, error: error.localizedDescription,
                ),
            )
            Log.images.warning(
                "Library prefetch failed for \(request.name): \(error.localizedDescription)",
            )
        }
    }
}
