import CryptoKit
import Foundation
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

public enum ExpectedChecksum: Sendable {
    case sha256(String)
    case sha512(String)
}

public actor ImageDownloader {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var continuations: [String: [UUID: AsyncStream<ImageProgressEvent>.Continuation]] = [:]
    private let dbPool: () -> GRDB.DatabasePool

    /// Shared session for all downloads (reuses connections, avoids per-download overhead)
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3_600
        return URLSession(configuration: config)
    }()

    public init(dbPool: @escaping @Sendable () -> GRDB.DatabasePool) {
        self.dbPool = dbPool
    }

    private static let maxRetries = 3
    private static let initialBackoff: UInt64 = 2_000_000_000 // 2s

    public func start(
        imageID: String, url: URL, destination: URL, expectedChecksum: ExpectedChecksum? = nil,
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await downloadWithRetry(
                    imageID: imageID, url: url, destination: destination, expectedChecksum: expectedChecksum,
                )
            } catch {
                await handleDownloadError(imageID: imageID, error: error)
            }
        }
        tasks[imageID] = task
    }

    private func downloadWithRetry(
        imageID: String, url: URL, destination: URL, expectedChecksum: ExpectedChecksum?,
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
                    imageID: imageID, url: url, destination: destination, expectedChecksum: expectedChecksum,
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
        imageID: String, url: URL, destination: URL, expectedChecksum: ExpectedChecksum?,
    ) async throws {
        let (asyncBytes, response) = try await Self.downloadSession.bytes(from: url)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200 ... 299).contains(statusCode) {
            throw BarkVisorError.downloadFailed("HTTP \(statusCode) from \(url)")
        }
        let total = httpResponse?.expectedContentLength ?? -1

        let received = try await downloadToFile(
            imageID: imageID, asyncBytes: asyncBytes, destination: destination, total: total,
        )

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

        let pool = dbPool()
        try await pool.write { db in
            try db.execute(
                sql:
                "UPDATE images SET status = 'ready', path = ?, sizeBytes = ?, updatedAt = ? WHERE id = ?",
                arguments: [finalPath.path, finalSize, iso8601.string(from: Date()), imageID],
            )
        }

        let doneEvent = ImageProgressEvent(
            id: imageID, status: "ready",
            bytesReceived: received, totalBytes: received,
            percent: 100, error: nil,
        )
        emit(imageID: imageID, event: doneEvent)
        finish(imageID: imageID)
    }

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

                let event = ImageProgressEvent(
                    id: imageID,
                    status: "downloading",
                    bytesReceived: received,
                    totalBytes: total < 0 ? nil : total,
                    percent: total > 0 ? Int((Double(received) / Double(total)) * 100) : nil,
                    error: nil,
                )
                emit(imageID: imageID, event: event)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        return received
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

        let fileData = try Data(contentsOf: destination)
        let computed: String
        let algorithm: String
        let expected: String

        switch expectedChecksum {
        case let .sha256(hash):
            computed = SHA256.hash(data: fileData).compactMap { String(format: "%02x", $0) }.joined()
            algorithm = "SHA256"
            expected = hash.lowercased()
        case let .sha512(hash):
            computed = SHA512.hash(data: fileData).compactMap { String(format: "%02x", $0) }.joined()
            algorithm = "SHA512"
            expected = hash.lowercased()
        }

        guard computed == expected else {
            try? FileManager.default.removeItem(at: destination)
            throw BarkVisorError.downloadFailed(
                "\(algorithm) mismatch: expected \(expected), got \(computed)",
            )
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

    public func progressStream(imageID: String) -> AsyncStream<ImageProgressEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[imageID, default: [:]][id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(imageID: imageID, id: id) }
            }
        }
    }

    public func cancel(imageID: String) {
        tasks[imageID]?.cancel()
        tasks.removeValue(forKey: imageID)
        finish(imageID: imageID)
    }

    private func emit(imageID: String, event: ImageProgressEvent) {
        guard let conts = continuations[imageID] else { return }
        for cont in conts.values {
            cont.yield(event)
        }
    }

    private func finish(imageID: String) {
        tasks.removeValue(forKey: imageID)
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
