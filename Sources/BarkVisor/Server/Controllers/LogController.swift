import BarkVisorCore
import Foundation
import Vapor

private nonisolated(unsafe) let iso8601Fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions.insert(.withFractionalSeconds)
    return f
}()

private func parseISO8601(_ string: String) -> Date? {
    iso8601.date(from: string) ?? iso8601Fractional.date(from: string)
}

struct LogController: RouteCollection {
    let vmState: any VMStateQuerying
    let backgroundTasks: BackgroundTaskManager

    func boot(routes: any RoutesBuilder) throws {
        let logs = routes.grouped("api", "logs")
        logs.get(use: queryLogs)
        logs.get("stream", use: streamLogs)
        logs.post("client-error", use: clientError)

        let diag = routes.grouped("api", "diagnostics")
        diag.post("bundle", use: diagnosticBundle)
        diag.get("bundle", ":taskID", "download", use: downloadDiagnosticBundle)
    }

    // MARK: - Application Logs

    @Sendable
    func queryLogs(req: Request) async throws -> Response {
        let category = req.query[String.self, at: "category"].flatMap { LogCategory(rawValue: $0) }
        let level = req.query[String.self, at: "level"].flatMap { LogLevel(rawValue: $0) }
        let sinceStr = req.query[String.self, at: "since"]
        let since = sinceStr.flatMap { parseISO8601($0) }
        let limit = req.query[Int.self, at: "limit"] ?? 500
        let search = req.query[String.self, at: "search"]

        let entries = await LogService.shared.readLogs(
            category: category, level: level, since: since,
            limit: min(limit, 5_000), search: search,
        )

        let data = try JSONEncoder().encode(entries)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    @Sendable
    func streamLogs(req: Request) async throws -> Response {
        let stream = await LogService.shared.tailLogs()
        return SSEResponse.stream(from: stream)
    }

    // MARK: - Client Error Reporting

    @Sendable
    func clientError(req: Request) async throws -> HTTPStatus {
        struct ClientErrorPayload: Content {
            let error: String
            var component: String?
            var stack: String?
            var type: String?
        }

        let payload = try req.content.decode(ClientErrorPayload.self)

        // Truncate fields to prevent log injection / disk exhaustion
        let maxLen = 4_096
        let safeError = String(payload.error.prefix(maxLen))
        let safeComponent = payload.component.map { String($0.prefix(256)) }
        let safeType = payload.type.map { String($0.prefix(128)) }

        await LogService.shared.log(
            .error,
            "Frontend: \(safeError)",
            category: .app,
            detail: [
                "component": safeComponent ?? "",
                "type": safeType ?? "vue-error",
            ].compactMapValues { $0.isEmpty ? nil : $0 },
        )
        return .noContent
    }

    // MARK: - Diagnostic Bundle

    @Sendable
    func diagnosticBundle(req: Request) async throws -> Response {
        let taskID = "diagnostic-bundle:\(UUID().uuidString.prefix(8))"
        let vmState = vmState

        await backgroundTasks.submit(taskID, kind: .diagnosticBundle) { @Sendable in
            try await DiagnosticService.generateBundle(vmState: vmState)
        }

        let response = TaskAcceptedResponse(taskID: taskID)
        let data = try JSONEncoder().encode(response)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .accepted, headers: headers, body: .init(data: data))
    }

    @Sendable
    func downloadDiagnosticBundle(req: Request) async throws -> Response {
        guard let taskID = req.parameters.get("taskID") else {
            throw Abort(.badRequest)
        }

        guard let event = await backgroundTasks.status(taskID) else {
            throw Abort(.notFound, reason: "Task not found")
        }

        guard event.status == .completed else {
            throw Abort(
                .conflict, reason: "Diagnostic bundle is not ready yet (status: \(event.status.rawValue))",
            )
        }

        guard let archivePath = event.resultPayload else {
            throw Abort(.gone, reason: "Diagnostic bundle file has expired or been cleaned up")
        }

        // Validate the path is within the system temp directory (prevent path traversal)
        let resolvedPath = (archivePath as NSString).resolvingSymlinksInPath
        let tempDir = (FileManager.default.temporaryDirectory.path as NSString).resolvingSymlinksInPath
        let tempDirWithSlash = tempDir.hasSuffix("/") ? tempDir : tempDir + "/"
        guard resolvedPath.hasPrefix(tempDirWithSlash) || resolvedPath == tempDir else {
            throw Abort(.forbidden, reason: "Invalid bundle path")
        }
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw Abort(.gone, reason: "Diagnostic bundle file has expired or been cleaned up")
        }

        // Sanitize filename for Content-Disposition header
        let rawName = URL(fileURLWithPath: resolvedPath).lastPathComponent
        let archiveName = rawName.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
        let response = try await req.fileio.asyncStreamFile(at: resolvedPath)
        response.headers.add(
            name: .contentDisposition, value: "attachment; filename=\"\(archiveName)\"",
        )
        return response
    }
}
