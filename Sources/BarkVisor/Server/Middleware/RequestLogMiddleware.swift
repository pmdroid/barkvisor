import BarkVisorCore
import Vapor

struct RequestLogMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let requestId = String(UUID().uuidString.prefix(12))
        let start = DispatchTime.now()

        // Attach request ID for downstream use
        request.storage[RequestIdKey.self] = requestId

        let response: Response
        do {
            response = try await next.respond(to: request)
        } catch {
            let elapsed = elapsedMs(since: start)

            await LogService.shared.log(
                .error,
                "\(request.method) \(request.url.path) → 500 (\(elapsed)ms)",
                category: .server,
                req: requestId,
                error: error.localizedDescription,
            )
            throw error
        }

        let elapsed = elapsedMs(since: start)
        let level: LogLevel =
            response.status.code >= 500
                ? .error
                : response.status.code >= 400
                ? .warn
                : .info

        await LogService.shared.log(
            level,
            "\(request.method) \(request.url.path) → \(response.status.code) (\(elapsed)ms)",
            category: .server,
            req: requestId,
        )

        response.headers.add(name: "X-Request-Id", value: requestId)
        return response
    }

    private func elapsedMs(since start: DispatchTime) -> Int {
        Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}

struct RequestIdKey: StorageKey {
    typealias Value = String
}
