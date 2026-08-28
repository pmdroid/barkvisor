#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation
import NIOCore

enum SSRFPinnedFileDownload {
    private static let progressChunk = 1_024 * 1_024

    static func streamToFile(
        from url: URL,
        to destination: URL,
        timeout: TimeInterval,
        allowedHosts: Set<String>? = nil,
        onProgress: @escaping @Sendable (Int64, Int64?) async -> Void = { _, _ in },
    ) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let pin = try SSRFPinnedURLProtocol.pinEndpoint(url: url)
        let hopClient = SSRFPinnedHopClient(timeout: timeout)
        do {
            let final = try await SSRFPinnedHopSession.finalResponse(
                request: request,
                url: url,
                pin: pin,
                allowedHosts: allowedHosts,
                hopClient: hopClient,
            )
            let status = Int(final.head.status.code)
            guard (200 ... 299).contains(status) else {
                for try await _ in final.body {
                    try Task.checkCancellation()
                }
                throw BarkVisorError.downloadFailed("HTTP \(status) from \(final.url)")
            }
            let total: Int64? = {
                guard let raw = final.head.headers.first(name: "content-length"),
                      let length = Int64(raw), length >= 0
                else { return nil }
                return length
            }()
            let received = try await writeBody(
                final.body, to: destination, totalBytes: total, onProgress: onProgress,
            )
            await hopClient.shutdown()
            return received
        } catch {
            await hopClient.shutdown()
            throw error
        }
    }

    static func writeBody(
        _ body: AsyncThrowingStream<ByteBuffer, Error>,
        to destination: URL,
        totalBytes: Int64?,
        onProgress: @escaping @Sendable (Int64, Int64?) async -> Void = { _, _ in },
    ) async throws -> Int64 {
        let parentDir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw BarkVisorError.downloadFailed("Failed to create file at \(destination.path)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        var received: Int64 = 0
        var sinceProgress: Int64 = 0
        do {
            for try await buffer in body {
                try Task.checkCancellation()
                let data = Data(buffer.readableBytesView)
                if data.isEmpty { continue }
                try handle.write(contentsOf: data)
                received += Int64(data.count)
                sinceProgress += Int64(data.count)
                if sinceProgress >= progressChunk {
                    sinceProgress = 0
                    await onProgress(received, totalBytes)
                }
            }
            try handle.close()
            return received
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
