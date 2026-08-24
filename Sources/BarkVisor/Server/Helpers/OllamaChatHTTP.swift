import BarkVisorCore
import Foundation
import Vapor

enum OllamaChatHTTP {
    static func response(status: Int, headers: [(String, String)], body: Data) -> Response {
        var http = HTTPHeaders()
        for (name, value) in OllamaChatProxy.forwardedHeaders(headers) {
            http.replaceOrAdd(name: name, value: value)
        }
        return Response(
            status: HTTPResponseStatus(statusCode: status),
            headers: http,
            body: .init(data: body),
        )
    }
}
