import Foundation
import Vapor

struct FoundationStaticFileMiddleware: Middleware {
    let publicDirectory: String
    let defaultFile: String

    func respond(to request: Request, chainingTo next: any Responder) -> EventLoopFuture<Response> {
        guard request.method == .GET || request.method == .HEAD else {
            return next.respond(to: request)
        }
        let rawPath = request.url.path
        if rawPath.hasPrefix("/api/") || rawPath.hasPrefix("/v1/") {
            return next.respond(to: request)
        }
        guard let decoded = rawPath.removingPercentEncoding else {
            return request.eventLoop.makeFailedFuture(Abort(.badRequest))
        }
        if decoded.contains("..") {
            return request.eventLoop.makeFailedFuture(Abort(.forbidden))
        }
        var relative = decoded
        while relative.hasPrefix("/") {
            relative.removeFirst()
        }
        while relative.hasPrefix("\\") {
            relative.removeFirst()
        }
        let root = URL(fileURLWithPath: publicDirectory, isDirectory: true)
        var url = relative.isEmpty ? root : root.appendingPathComponent(relative)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            url = url.appendingPathComponent(defaultFile)
        } else if relative.isEmpty {
            url = root.appendingPathComponent(defaultFile)
        }
        let rootFold = root.standardizedFileURL.path.replacingOccurrences(of: "\\", with: "/").lowercased()
        let fileFold = url.standardizedFileURL.path.replacingOccurrences(of: "\\", with: "/").lowercased()
        let rootPrefix = rootFold.hasSuffix("/") ? rootFold : rootFold + "/"
        if fileFold != rootFold, !fileFold.hasPrefix(rootPrefix) {
            return request.eventLoop.makeFailedFuture(Abort(.forbidden))
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return next.respond(to: request)
        }
        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            let media = HTTPMediaType.fileExtension(ext)
                ?? HTTPMediaType(type: "application", subType: "octet-stream")
            var headers = HTTPHeaders()
            headers.contentType = media
            let body: Response.Body = request.method == .HEAD ? .empty : .init(data: data)
            if request.method == .HEAD {
                headers.replaceOrAdd(name: .contentLength, value: String(data.count))
            }
            return request.eventLoop.makeSucceededFuture(
                Response(status: .ok, headers: headers, body: body),
            )
        } catch {
            return next.respond(to: request)
        }
    }
}
