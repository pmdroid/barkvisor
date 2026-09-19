import Vapor

struct DisplayHomeMiddleware: AsyncMiddleware {
    let home: HomeDevicesController

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder,
    ) async throws -> Response {
        if request.method == .GET, request.url.path == "/display/home" {
            return try await home.displayHome(req: request)
        }
        return try await next.respond(to: request)
    }
}
