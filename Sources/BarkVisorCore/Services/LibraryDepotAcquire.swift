import Foundation
import GRDB

/// Copy a ready depot image into this Device's Library on a local miss.
///
/// Failures never throw to the caller — they audit-log and return `nil` so
/// deploy/download keeps today's internet path (PAS-47 / PAS-90). Local
/// Workload start does not call this.
public struct LibraryDepotAcquire: LibraryDepotFetching {
    public var localHostId: String
    public var dataDir: URL
    public var devices: DeviceRegistry
    public var openClient: @Sendable (DeviceRecord) throws -> any LibraryDepotClient

    public init(
        localHostId: String,
        dataDir: URL,
        devices: DeviceRegistry,
        openClient: @escaping @Sendable (DeviceRecord) throws -> any LibraryDepotClient,
    ) {
        self.localHostId = localHostId
        self.dataDir = dataDir
        self.devices = devices
        self.openClient = openClient
    }

    public func fetchMatching(_ request: LibraryDepotFetchRequest, db: DatabasePool) async -> VMImage? {
        guard let depotHostId = try? await db.read({ try LibrarySettings.resolvedDepotHostId(from: $0) }),
              depotHostId != localHostId
        else {
            return nil
        }
        guard let client = await client(for: depotHostId, sourceUrl: request.sourceUrl, db: db) else {
            return nil
        }
        guard let remote = await lookup(request.sourceUrl, client: client, db: db) else {
            return nil
        }
        return await copyRemote(remote, request: request, depotHostId: depotHostId, client: client, db: db)
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

    private func copyRemote(
        _ remote: LibraryDepotImageInfo,
        request: LibraryDepotFetchRequest,
        depotHostId: String,
        client: any LibraryDepotClient,
        db: DatabasePool,
    ) async -> VMImage? {
        let imageId = UUID().uuidString
        let destination: URL
        do {
            let imagesDir = try await db.read { try Config.imagesDir(from: $0) }
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            let filename = remote.filename
                ?? URL(string: request.sourceUrl)?.lastPathComponent
                ?? "image"
            let ext = ImageService.imageExtension(from: filename, imageType: request.imageType)
            destination = imagesDir.appendingPathComponent("\(imageId).\(ext)")
        } catch {
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "Library directory unavailable: \(error.localizedDescription)",
            )
            return nil
        }

        let fetched: LibraryDepotFetchBytes
        do {
            fetched = try await client.fetchBytes(imageId: remote.id, to: destination)
            try verify(
                destination: destination,
                computedSha256: fetched.sha256,
                remoteSha256: fetched.reportedSha256 ?? remote.sha256,
                expectedChecksum: request.expectedChecksum,
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "depot fetch failed: \(error.localizedDescription)",
            )
            return nil
        }

        return await persist(
            imageId: imageId,
            request: request,
            destination: destination,
            fetched: fetched,
            depotHostId: depotHostId,
            db: db,
        )
    }

    private func persist(
        imageId: String,
        request: LibraryDepotFetchRequest,
        destination: URL,
        fetched: LibraryDepotFetchBytes,
        depotHostId: String,
        db: DatabasePool,
    ) async -> VMImage? {
        let now = iso8601.string(from: Date())
        let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let image = VMImage(
            id: imageId,
            name: request.name,
            imageType: request.imageType,
            arch: request.arch,
            path: destination.path,
            sizeBytes: (attrs?[.size] as? Int64) ?? fetched.bytesWritten,
            status: "ready",
            error: nil,
            sourceUrl: request.sourceUrl,
            sha256: fetched.sha256,
            createdAt: now,
            updatedAt: now,
        )
        do {
            try await db.write { db in
                try image.insert(db)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            await fallback(
                db: db, sourceUrl: request.sourceUrl,
                reason: "could not record depot image: \(error.localizedDescription)",
            )
            return nil
        }
        await AuditService.logSystem(
            action: "library.depot.fetch",
            detail: "copied \(request.sourceUrl) from Device \(depotHostId)",
            db: db,
        )
        Log.images.info("Library depot fetch ready for \(request.sourceUrl) from Device \(depotHostId)")
        return image
    }

    private func verify(
        destination: URL,
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
        guard let expectedChecksum else { return }
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

    private func fallback(db: DatabasePool, sourceUrl: String, reason: String) async {
        await AuditService.logSystem(
            action: "library.depot.fallback",
            detail: "\(reason) (\(sourceUrl))",
            db: db,
        )
        Log.images.warning("Library depot fallback: \(reason)")
    }
}
