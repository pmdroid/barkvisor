import BarkVisorCore
import Foundation
import GRDB
import Vapor

extension LibraryDepotImageInfo: Content {}

/// Streamed Library listing + image bytes on the mTLS agent plane (7778).
///
/// Registered on ``AgentTLSServer`` only. The Home proxy (10 MiB, buffered)
/// must not carry `/content`.
struct AgentLibraryController: RouteCollection {
    var db: DatabasePool?

    func boot(routes: any RoutesBuilder) throws {
        let library = routes.grouped("api", "agent", "library", "images")
        library.get(use: list)
        library.get(":id", "content", use: content)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [LibraryDepotImageInfo] {
        guard let db else {
            throw Abort(.notFound)
        }
        let sourceUrl = req.query[String.self, at: "sourceUrl"]
        let sha256 = req.query[String.self, at: "sha256"]
        return try await db.read { db in
            try LibraryDepotCatalog.list(db: db, sourceUrl: sourceUrl, sha256: sha256)
        }
    }

    @Sendable
    func content(req: Vapor.Request) async throws -> Response {
        guard let db else {
            throw Abort(.notFound)
        }
        guard let id = req.parameters.get("id"), !id.isEmpty else {
            throw Abort(.badRequest)
        }
        let file: LibraryDepotFile
        do {
            file = try await db.read { db in
                try LibraryDepotCatalog.readyFile(db: db, id: id)
            }
        } catch let error as BarkVisorError {
            throw error
        }
        var response = req.fileio.streamFile(at: file.url.path)
        response.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
        response.headers.replaceOrAdd(name: LibraryDepotHTTP.imageIdHeader, value: file.image.id)
        response.headers.replaceOrAdd(name: LibraryDepotHTTP.nameHeader, value: file.image.name)
        response.headers.replaceOrAdd(name: LibraryDepotHTTP.archHeader, value: file.image.arch)
        if let sha = file.image.sha256, !sha.isEmpty {
            response.headers.replaceOrAdd(name: LibraryDepotHTTP.sha256Header, value: sha)
        }
        if let source = file.image.sourceUrl, !source.isEmpty {
            response.headers.replaceOrAdd(name: LibraryDepotHTTP.sourceUrlHeader, value: source)
        }
        if let filename = file.info.filename, !filename.isEmpty {
            response.headers.replaceOrAdd(name: LibraryDepotHTTP.filenameHeader, value: filename)
        }
        return response
    }
}
