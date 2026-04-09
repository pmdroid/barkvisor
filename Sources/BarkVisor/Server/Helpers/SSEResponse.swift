import BarkVisorCore
import Foundation
import NIOCore
import Vapor

enum SSEResponse {
    /// Create a Server-Sent Events response from an async sequence of Encodable events.
    static func stream<S: AsyncSequence & Sendable>(
        from sequence: S,
        encoder: JSONEncoder = JSONEncoder(),
    ) -> Response where S.Element: Encodable {
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
                    for try await event in sequence {
                        if let data = try? encoder.encode(event),
                           let json = String(data: data, encoding: .utf8) {
                            try await writer.write(.buffer(.init(string: "data: \(json)\n\n")))
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
}
