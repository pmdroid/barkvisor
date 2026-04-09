import BarkVisorCore
import Foundation
import Vapor

/// Serves index.html for any GET request that doesn't match an API route or static file.
/// This enables Vue Router's history mode (client-side routing).
struct SPAFallbackMiddleware: Middleware {
    let indexPath: String

    func respond(to request: Vapor.Request, chainingTo next: any Responder) -> EventLoopFuture<
        Vapor.Response,
    > {
        // For non-API GET requests that look like SPA routes (no file extension),
        // serve index.html directly without going through the rest of the chain
        if request.method == .GET,
           !request.url.path.hasPrefix("/api/"),
           !request.url.path.contains("."),
           request.url.path != "/" {
            do {
                let indexData = try Data(contentsOf: URL(fileURLWithPath: indexPath))
                let res = Response(
                    status: .ok,
                    headers: HTTPHeaders([("Content-Type", "text/html; charset=utf-8")]),
                    body: .init(data: indexData),
                )
                return request.eventLoop.makeSucceededFuture(res)
            } catch {
                // Fall through to normal handling
            }
        }
        return next.respond(to: request)
    }
}
