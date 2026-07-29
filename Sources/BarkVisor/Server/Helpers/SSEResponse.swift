import BarkVisorCore
import Foundation
import NIOCore
import Vapor

enum SSEResponse {
    /// Create a Server-Sent Events response from an async sequence of Encodable events.
    /// - Parameter keepaliveSeconds: When set, emit SSE comment keepalives on this interval
    ///   so proxies/browsers do not idle-close long-lived streams (e.g. VM state).
    static func stream<S: AsyncSequence & Sendable>(
        from sequence: S,
        encoder: JSONEncoder = JSONEncoder(),
        keepaliveSeconds: Int? = nil,
    ) -> Response where S.Element: Encodable & Sendable {
        let headers = HTTPHeaders([
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
            ("X-Accel-Buffering", "no"),
        ])

        return Response(
            status: .ok, headers: headers,
            body: .init(asyncStream: { writer in
                do {
                    if let keepaliveSeconds, keepaliveSeconds > 0 {
                        let chunks = Self.mergedSSEChunks(
                            sequence: sequence,
                            encoder: encoder,
                            keepaliveSeconds: keepaliveSeconds,
                        )
                        for await chunk in chunks {
                            try await writer.write(.buffer(.init(string: chunk)))
                        }
                    } else {
                        for try await event in sequence {
                            if let data = try? encoder.encode(event),
                               let json = String(data: data, encoding: .utf8) {
                                try await writer.write(.buffer(.init(string: "data: \(json)\n\n")))
                            }
                        }
                    }
                    try await writer.write(.end)
                } catch {
                    let isBrokenPipe =
                        (error as? IOError)?.errnoCode == EPIPE
                            || "\(error)".contains("Broken pipe")
                    if !isBrokenPipe {
                        Log.server.error("SSE stream error: \(error)")
                    }
                    try? await writer.write(.end)
                }
            }),
        )
    }

    /// Merge JSON data events with periodic `: keepalive` comments.
    private static func mergedSSEChunks<S: AsyncSequence & Sendable>(
        sequence: S,
        encoder: JSONEncoder,
        keepaliveSeconds: Int,
    ) -> AsyncStream<String> where S.Element: Encodable & Sendable {
        AsyncStream { continuation in
            let eventTask = Task {
                do {
                    for try await event in sequence {
                        if let data = try? encoder.encode(event),
                           let json = String(data: data, encoding: .utf8) {
                            continuation.yield("data: \(json)\n\n")
                        }
                    }
                } catch {
                    // Sequence finished with error; outer writer handles logging.
                }
                continuation.finish()
            }
            let keepaliveTask = Task {
                let nanos = UInt64(keepaliveSeconds) * 1_000_000_000
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: nanos)
                    guard !Task.isCancelled else { break }
                    continuation.yield(": keepalive\n\n")
                }
            }
            continuation.onTermination = { _ in
                eventTask.cancel()
                keepaliveTask.cancel()
            }
        }
    }
}

extension Response {
    /// Encode a value as `application/json` with the given HTTP status.
    static func json(_ value: some Encodable, status: HTTPStatus = .ok) throws -> Response {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}
