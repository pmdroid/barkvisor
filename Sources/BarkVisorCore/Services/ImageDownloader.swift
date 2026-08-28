import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import GRDB

public struct ImageProgressEvent: Codable, Sendable {
    public let id: String
    public let status: String
    public let bytesReceived: Int64
    public let totalBytes: Int64?
    public let percent: Int?
    public let error: String?

    public init(
        id: String,
        status: String,
        bytesReceived: Int64,
        totalBytes: Int64?,
        percent: Int?,
        error: String?,
    ) {
        self.id = id
        self.status = status
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.percent = percent
        self.error = error
    }
}

public enum ExpectedChecksum: Sendable, Equatable {
    case sha256(String)
    case sha512(String)

    /// Prefer sha256 when the catalog lists both.
    public static func catalog(sha256: String?, sha512: String?) -> ExpectedChecksum? {
        if let sha256, !sha256.isEmpty { return .sha256(sha256) }
        if let sha512, !sha512.isEmpty { return .sha512(sha512) }
        return nil
    }

    public static func catalog(from image: RepositoryImage) -> ExpectedChecksum? {
        catalog(sha256: image.sha256, sha512: image.sha512)
    }
}

/// Starts catalog/image downloads. Extracted so tests can assert `start` is never called.
public protocol ImageDownloadStarting: Actor {
    func start(
        imageID: String,
        url: URL,
        destination: URL,
        expectedChecksum: ExpectedChecksum?,
        expectedStoredSha256: String?,
    )
}

/// Publishes Library download progress (internet or depot) onto SSE subscribers.
public protocol ImageProgressPublishing: Actor {
    func publish(_ event: ImageProgressEvent)
}

public actor ImageDownloader: ImageDownloadStarting, ImageProgressPublishing {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var continuations: [String: [UUID: AsyncStream<ImageProgressEvent>.Continuation]] = [:]
    /// Last event per image so SSE subscribers that join after `start` still
    /// see in-flight percent (and `ready` / `error` after the download ends).
    private var lastEvents: [String: ImageProgressEvent] = [:]
    private var libraryPollers: [String: Task<Void, Never>] = [:]
    private let dbPool: () -> GRDB.DatabasePool

    #if !(canImport(FoundationNetworking) && !canImport(Darwin))
        /// Shared session for all downloads (reuses connections, avoids per-download overhead).
        /// Redirects are gated by SSRFGuard.validate so a public URL cannot 302 to loopback.
        private static let downloadSession: URLSession = SSRFGuard.urlSession(resourceTimeout: 3_600)
    #endif

    public init(dbPool: @escaping @Sendable () -> GRDB.DatabasePool) {
        self.dbPool = dbPool
    }

    private static let maxRetries = 3
    private static let initialBackoff: UInt64 = 2_000_000_000 // 2s

    public func start(
        imageID: String,
        url: URL,
        destination: URL,
        expectedChecksum: ExpectedChecksum? = nil,
        expectedStoredSha256: String? = nil,
    ) {
        // Seed last-event so GET /images and late SSE subscribers do not replay
        // a previous ready/error from a retried row.
        emit(
            imageID: imageID,
            event: ImageProgressEvent(
                id: imageID, status: "downloading",
                bytesReceived: 0, totalBytes: nil,
                percent: nil, error: nil,
            ),
        )
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await downloadWithRetry(
                    imageID: imageID,
                    url: url,
                    destination: destination,
                    expectedChecksum: expectedChecksum,
                    expectedStoredSha256: expectedStoredSha256,
                )
            } catch {
                await handleDownloadError(imageID: imageID, error: error)
            }
        }
        tasks[imageID] = task
    }

    private func downloadWithRetry(
        imageID: String,
        url: URL,
        destination: URL,
        expectedChecksum: ExpectedChecksum?,
        expectedStoredSha256: String?,
    ) async throws {
        var lastError: Error?

        for attempt in 0 ... Self.maxRetries {
            if attempt > 0 {
                let backoff = Self.initialBackoff * UInt64(1 << (attempt - 1))
                Log.images.info(
                    "Retrying download for \(imageID) (attempt \(attempt + 1)/\(Self.maxRetries + 1)) after \(backoff / 1_000_000_000)s",
                )
                let retryEvent = ImageProgressEvent(
                    id: imageID, status: "retrying",
                    bytesReceived: 0, totalBytes: nil,
                    percent: nil, error: "Retry \(attempt + 1)/\(Self.maxRetries + 1)...",
                )
                emit(imageID: imageID, event: retryEvent)
                try? await Task.sleep(nanoseconds: backoff)
            }

            do {
                try Task.checkCancellation()
                try await performDownload(
                    imageID: imageID,
                    url: url,
                    destination: destination,
                    expectedChecksum: expectedChecksum,
                    expectedStoredSha256: expectedStoredSha256,
                )
                return // Success
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                Log.images.warning("Download attempt \(attempt + 1) failed for \(imageID): \(error)")
            }
        }

        throw lastError
            ?? BarkVisorError.downloadFailed("Download failed after \(Self.maxRetries + 1) attempts")
    }

    private func handleDownloadError(imageID: String, error: Error) async {
        let pool = dbPool()
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE images SET status = 'error', error = ?, updatedAt = ? WHERE id = ?",
                    arguments: [error.localizedDescription, iso8601.string(from: Date()), imageID],
                )
            }
        } catch {
            Log.images.error("Failed to update error state for image \(imageID): \(error)")
        }

        let errEvent = ImageProgressEvent(
            id: imageID, status: "error",
            bytesReceived: 0, totalBytes: nil,
            percent: nil, error: error.localizedDescription,
        )
        emit(imageID: imageID, event: errEvent)
        finish(imageID: imageID)
    }

    private func performDownload(
        imageID: String,
        url: URL,
        destination: URL,
        expectedChecksum: ExpectedChecksum?,
        expectedStoredSha256: String?,
    ) async throws {
        if !url.isFileURL, let ssrfError = SSRFGuard.fetchRejection(for: url) {
            throw BarkVisorError.downloadFailed(ssrfError)
        }
        #if canImport(FoundationNetworking) && !canImport(Darwin)
            let received = try await SSRFPinnedFileDownload.streamToFile(
                from: url,
                to: destination,
                timeout: 3_600,
            ) { received, total in
                await self.emitDownloading(imageID: imageID, received: received, total: total)
            }
        #else
            let (asyncBytes, response) = try await Self.downloadSession.bytes(from: url)
            let httpResponse = response as? HTTPURLResponse
            if let statusCode = httpResponse?.statusCode, !(200 ... 299).contains(statusCode) {
                throw BarkVisorError.downloadFailed("HTTP \(statusCode) from \(url)")
            }
            let total = httpResponse?.expectedContentLength ?? -1

            let received = try await downloadToFile(
                imageID: imageID, asyncBytes: asyncBytes, destination: destination, total: total,
            )
        #endif

        if let expectedChecksum {
            try verifyChecksum(
                imageID: imageID,
                destination: destination,
                expectedChecksum: expectedChecksum,
                received: received,
            )
        }

        let finalPath = try decompressIfNeeded(
            imageID: imageID,
            destination: destination,
            received: received,
        )

        let finalSize =
            (try? FileManager.default.attributesOfItem(atPath: finalPath.path)[.size] as? Int64)
                ?? received

        // Persist sha256 of the stored file (after decompress). Catalog sha512 is
        // verified above when present; the row always stores sha256 for depot verify.
        let digest = try ImageFileChecksum.sha256Hex(ofFile: finalPath)
        if let expectedStoredSha256 {
            let want = expectedStoredSha256.lowercased()
            if !want.isEmpty, digest.lowercased() != want {
                try? FileManager.default.removeItem(at: finalPath)
                throw BarkVisorError.downloadFailed(
                    "SHA256 mismatch: expected \(want), got \(digest.lowercased())",
                )
            }
        }
        try await LibraryAcquire.persistReady(
            imageId: imageID,
            path: finalPath.path,
            sizeBytes: finalSize,
            sha256: digest,
            db: dbPool(),
        )

        let doneEvent = ImageProgressEvent(
            id: imageID, status: "ready",
            bytesReceived: received, totalBytes: received,
            percent: 100, error: nil,
        )
        emit(imageID: imageID, event: doneEvent)
        finish(imageID: imageID)
    }

    #if !(canImport(FoundationNetworking) && !canImport(Darwin))
        private func downloadToFile(
            imageID: String, asyncBytes: URLSession.AsyncBytes,
            destination: URL, total: Int64,
        ) async throws -> Int64 {
            let parentDir = destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw BarkVisorError.downloadFailed("Failed to create file at \(destination.path)")
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var received: Int64 = 0
            var buffer = Data()
            let chunkSize = 1_024 * 1_024

            for try await byte in asyncBytes {
                buffer.append(byte)
                received += 1

                if buffer.count >= chunkSize {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    emitDownloading(
                        imageID: imageID,
                        received: received,
                        total: total < 0 ? nil : total,
                    )
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            return received
        }
    #endif

    private func emitDownloading(imageID: String, received: Int64, total: Int64?) {
        let totalValue = total ?? -1
        emit(
            imageID: imageID,
            event: ImageProgressEvent(
                id: imageID,
                status: "downloading",
                bytesReceived: received,
                totalBytes: total,
                percent: Self.clampedPercent(received: received, total: totalValue),
                error: nil,
            ),
        )
    }

    private func verifyChecksum(
        imageID: String, destination: URL,
        expectedChecksum: ExpectedChecksum, received: Int64,
    ) throws {
        let verifyEvent = ImageProgressEvent(
            id: imageID, status: "verifying",
            bytesReceived: received, totalBytes: received,
            percent: nil, error: nil,
        )
        emit(imageID: imageID, event: verifyEvent)

        do {
            try ImageFileChecksum.verify(ofFile: destination, expected: expectedChecksum)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let algorithm =
            switch expectedChecksum {
            case .sha256: "SHA256"
            case .sha512: "SHA512"
            }
        Log.images.info("\(algorithm) checksum verified for \(imageID)")
    }

    private func decompressIfNeeded(
        imageID: String, destination: URL, received: Int64,
    ) throws -> URL {
        let destPath = destination.path
        let isCompressed = [".xz", ".gz", ".zst", ".bz2"].contains(where: { destPath.hasSuffix($0) })
        guard isCompressed else { return destination }

        let decompressEvent = ImageProgressEvent(
            id: imageID, status: "decompressing",
            bytesReceived: received, totalBytes: nil,
            percent: nil, error: nil,
        )
        emit(imageID: imageID, event: decompressEvent)

        try Task.checkCancellation()

        return try ImageService.decompressIfNeeded(destination)
    }

    public func publish(_ event: ImageProgressEvent) {
        emit(imageID: event.id, event: event)
        if event.status == "ready" || event.status == "error" {
            finish(imageID: event.id)
        }
    }

    public func lastProgress(imageID: String) -> ImageProgressEvent? {
        lastEvents[imageID]
    }

    public func lastProgress(imageIDs: [String]) -> [String: ImageProgressEvent] {
        var out: [String: ImageProgressEvent] = [:]
        out.reserveCapacity(imageIDs.count)
        for id in imageIDs {
            if let event = lastEvents[id] {
                out[id] = event
            }
        }
        return out
    }

    public func progressStream(imageID: String) -> AsyncStream<ImageProgressEvent> {
        let id = UUID()
        if !Self.isTerminal(lastEvents[imageID]?.status) {
            startLibraryPollIfNeeded(imageID)
        }
        return AsyncStream { continuation in
            let register = Task { [weak self] in
                await self?.addContinuation(imageID: imageID, id: id, continuation: continuation)
            }
            continuation.onTermination = { _ in
                register.cancel()
                Task { [weak self] in
                    await self?.removeContinuation(imageID: imageID, id: id)
                }
            }
        }
    }

    private func addContinuation(
        imageID: String,
        id: UUID,
        continuation: AsyncStream<ImageProgressEvent>.Continuation,
    ) async {
        guard !Task.isCancelled else { return }
        continuations[imageID, default: [:]][id] = continuation
        if let last = lastEvents[imageID] {
            continuation.yield(last)
            if Self.isTerminal(last.status) {
                continuation.finish()
            }
            return
        }
        // finish() drops lastEvents. Snapshot the Library row so a subscriber
        // after ready/error still settles without leaking in-memory events.
        if let snapshot = await libraryTerminalEvent(imageID) {
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    private func libraryTerminalEvent(_ imageID: String) async -> ImageProgressEvent? {
        let image = try? await dbPool().read { db in
            try VMImage.fetchOne(db, key: imageID)
        }
        guard let image else { return nil }
        if image.status == "ready" {
            return ImageProgressEvent(
                id: imageID, status: "ready",
                bytesReceived: image.sizeBytes ?? 0,
                totalBytes: image.sizeBytes,
                percent: 100, error: nil,
            )
        }
        if image.status == "error" {
            return ImageProgressEvent(
                id: imageID, status: "error",
                bytesReceived: 0, totalBytes: nil,
                percent: nil, error: image.error,
            )
        }
        return nil
    }

    /// Depot copies write SQLite only. Poll the Library row so SSE/deploy
    /// subscribers still see ready/error when ImageDownloader never ran.
    private func startLibraryPollIfNeeded(_ imageID: String) {
        guard libraryPollers[imageID] == nil else { return }
        libraryPollers[imageID] = Task { [weak self] in
            await self?.pollLibraryRow(imageID)
        }
    }

    private func pollLibraryRow(_ imageID: String) async {
        defer { libraryPollers[imageID] = nil }
        for attempt in 0 ..< 1_800 {
            if Task.isCancelled { return }
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }
            let image = try? await dbPool().read { db in
                try VMImage.fetchOne(db, key: imageID)
            }
            guard let image else { continue }
            if image.status == "ready" {
                publish(
                    ImageProgressEvent(
                        id: imageID, status: "ready",
                        bytesReceived: image.sizeBytes ?? 0,
                        totalBytes: image.sizeBytes,
                        percent: 100, error: nil,
                    ),
                )
                return
            }
            if image.status == "error" {
                publish(
                    ImageProgressEvent(
                        id: imageID, status: "error",
                        bytesReceived: 0, totalBytes: nil,
                        percent: nil, error: image.error,
                    ),
                )
                return
            }
        }
    }

    public func cancel(imageID: String) {
        tasks[imageID]?.cancel()
        tasks.removeValue(forKey: imageID)
        finish(imageID: imageID)
    }

    private func emit(imageID: String, event: ImageProgressEvent) {
        let event = Self.normalized(event)
        lastEvents[imageID] = event
        guard let conts = continuations[imageID] else { return }
        for cont in conts.values {
            cont.yield(event)
        }
    }

    /// Display percent is 0...100. Nil when total size is unknown.
    private static func clampedPercent(received: Int64, total: Int64) -> Int? {
        guard total > 0 else { return nil }
        let value = Int((Double(received) / Double(total)) * 100)
        return min(100, max(0, value))
    }

    private static func normalized(_ event: ImageProgressEvent) -> ImageProgressEvent {
        guard let percent = event.percent else { return event }
        let clamped = min(100, max(0, percent))
        guard clamped != percent else { return event }
        return ImageProgressEvent(
            id: event.id,
            status: event.status,
            bytesReceived: event.bytesReceived,
            totalBytes: event.totalBytes,
            percent: clamped,
            error: event.error,
        )
    }

    private static func isTerminal(_ status: String?) -> Bool {
        status == "ready" || status == "error"
    }

    private func finish(imageID: String) {
        lastEvents.removeValue(forKey: imageID)
        tasks.removeValue(forKey: imageID)
        libraryPollers.removeValue(forKey: imageID)?.cancel()
        if let conts = continuations.removeValue(forKey: imageID) {
            for cont in conts.values {
                cont.finish()
            }
        }
    }

    private func removeContinuation(imageID: String, id: UUID) {
        continuations[imageID]?.removeValue(forKey: id)
        if continuations[imageID]?.isEmpty == true {
            continuations.removeValue(forKey: imageID)
        }
    }
}
