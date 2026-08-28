import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct DeviceNameResponse: Content {
    let displayName: String
    let hostname: String
}

struct DeviceNameRequest: Content {
    let displayName: String
}

struct DeviceNameController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let system = routes.grouped("api", "system")
        system.get("device-name", use: getName)
        system.put("device-name", use: updateName)
    }

    @Sendable
    func getName(req: Vapor.Request) async throws -> DeviceNameResponse {
        try await Self.load(req: req)
    }

    @Sendable
    func updateName(req: Vapor.Request) async throws -> DeviceNameResponse {
        let body = try req.content.decode(DeviceNameRequest.self)
        return try await Self.apply(req: req, displayName: body.displayName)
    }

    static func load(req: Vapor.Request) async throws -> DeviceNameResponse {
        let hostname = ProcessInfo.processInfo.hostName
        let displayName = try await req.db.read { db in
            try DeviceNameSettings.resolved(from: db, hostname: hostname)
        }
        return DeviceNameResponse(displayName: displayName, hostname: hostname)
    }

    static func apply(req: Vapor.Request, displayName: String) async throws -> DeviceNameResponse {
        let hostname = ProcessInfo.processInfo.hostName
        let saved = try await req.db.write { db in
            try DeviceNameSettings.save(displayName, db: db)
        }
        return DeviceNameResponse(displayName: saved, hostname: hostname)
    }
}
