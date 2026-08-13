import BarkVisorCore
import Vapor

/// Stamps `X-BarkVisor-API-Version` on every `/api` response, including errors.
struct APIVersionMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        if request.url.path.hasPrefix("/api") {
            response.headers.replaceOrAdd(
                name: APIContract.versionHeaderName,
                value: String(APIContract.version),
            )
        }
        return response
    }
}
