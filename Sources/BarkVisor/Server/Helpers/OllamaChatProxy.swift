import BarkVisorCore
import Foundation
import NIOCore
import Vapor

/// Forward Ollama OpenAI SSE bytes to the console (PAS-270).
enum OllamaChatProxy {
    static let streamTimeoutSeconds: Int64 = 3_600

    static func stream(_ chunks: AsyncThrowingStream<Data, Error>) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        headers.replaceOrAdd(name: "Connection", value: "keep-alive")
        headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        return Response(
            status: .ok,
            headers: headers,
            body: .init(asyncStream: { writer in
                do {
                    for try await chunk in chunks {
                        var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        try await writer.write(.buffer(buffer))
                    }
                    try await writer.write(.end)
                } catch {
                    try? await writer.write(.end)
                }
            }),
        )
    }

    static func buffered(status: Int, body: Data, stream: Bool, memberHeaders: [(String, String)] = [])
        -> Response {
        var headers = HTTPHeaders()
        if stream {
            let contentType = memberHeaders.first { $0.0.lowercased() == "content-type" }?.1
            headers.replaceOrAdd(name: .contentType, value: contentType ?? "text/event-stream")
            headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        } else {
            headers.replaceOrAdd(name: .contentType, value: "application/json")
        }
        return Response(
            status: HTTPResponseStatus(statusCode: status),
            headers: headers,
            body: .init(data: body),
        )
    }
}
