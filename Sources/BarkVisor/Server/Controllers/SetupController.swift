import BarkVisorCore
import Foundation
import GRDB
import JWTKit
import Vapor

/// Handles the web-based onboarding wizard. All endpoints are unprotected (no JWT)
/// but only accessible when setup has not been completed yet.
struct SetupController: RouteCollection {
    let setupMiddleware: SetupMiddleware
    let keys: JWTKeyCollection

    func boot(routes: any RoutesBuilder) throws {
        let setup = routes.grouped("api", "setup")
        setup.get("status", use: getStatus)
        setup.post("admin", use: createAdmin)
        setup.get("interfaces", use: listInterfaces)
        setup.post("bridge", use: installBridge)
        setup.post("bridge", "skip", use: skipBridge)
        setup.post("repositories", "sync", use: syncRepositories)
        setup.get("repositories", "status", use: repositorySyncStatus)
        setup.post("complete", use: complete)
    }

    // MARK: - Status

    struct StatusResponse: Content {
        let complete: Bool
    }

    @Sendable
    func getStatus(req: Request) async throws -> StatusResponse {
        StatusResponse(complete: setupMiddleware.isSetupComplete)
    }

    // MARK: - Admin User

    struct AdminRequest: Content {
        let username: String
        let password: String
    }

    struct AdminResponse: Content {
        let success: Bool
    }

    @Sendable
    func createAdmin(req: Request) async throws -> AdminResponse {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(AdminRequest.self)

        guard body.password.count >= 10 else {
            throw Abort(.badRequest, reason: "Password must be at least 10 characters")
        }
        guard !body.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "Username must not be empty")
        }

        let hash = try Bcrypt.hash(body.password)
        try await req.db.write { db in
            // Create user if not exists, or set password if empty
            if let existing = try User.filter(User.Columns.username == body.username).fetchOne(db) {
                guard existing.password.isEmpty else {
                    throw Abort(.conflict, reason: "Password already set for this user")
                }
                try db.execute(
                    sql: "UPDATE users SET password = ? WHERE username = ? AND password = ''",
                    arguments: [hash, body.username],
                )
            } else {
                let user = User(
                    id: UUID().uuidString,
                    username: body.username,
                    password: hash,
                    createdAt: iso8601.string(from: Date()),
                )
                try user.insert(db)
            }
        }

        return AdminResponse(success: true)
    }

    // MARK: - Network Interfaces & Bridge

    struct InterfaceResponse: Content {
        let name: String
        let displayName: String
        let ipAddress: String
        let bridgeStatus: String?
    }

    @Sendable
    func listInterfaces(req: Request) async throws -> [InterfaceResponse] {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }
        let bridgeRecords = try await req.db.read { db in
            try BridgeRecord.fetchAll(db)
        }
        let bridgeByInterface = Dictionary(
            uniqueKeysWithValues: bridgeRecords.map { ($0.interface, $0) },
        )

        let rawInterfaces = HostInfoService.listInterfaces()
        return rawInterfaces.map { iface in
            let displayName: String =
                if iface.name.hasPrefix("en") {
                    "\(iface.name) (Ethernet/Wi-Fi)"
                } else if iface.name.hasPrefix("bridge") {
                    "\(iface.name) (Bridge)"
                } else if iface.name == "lo0" {
                    "lo0 (Loopback)"
                } else {
                    iface.name
                }

            let bridge = bridgeByInterface[iface.name]
            return InterfaceResponse(
                name: iface.name,
                displayName: displayName,
                ipAddress: iface.ipAddress,
                bridgeStatus: bridge?.status == "not_configured" ? nil : bridge?.status,
            )
        }
    }

    struct BridgeRequest: Content {
        let interface: String
    }

    struct BridgeResponse: Content {
        let success: Bool
        let message: String?
    }

    @Sendable
    func installBridge(req: Request) async throws -> BridgeResponse {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(BridgeRequest.self)
        do {
            try await HelperXPCClient.shared.installBridge(interface: body.interface)
        } catch {
            let msg = error.localizedDescription
            // Bridge already configured is not an error during setup
            if !msg.contains("already exists") {
                return BridgeResponse(success: false, message: msg)
            }
        }

        // Sync bridge state into the DB immediately
        await BridgeSyncService.syncOnce(db: req.db)

        // Create a bridged network record if one doesn't exist for this interface
        let existing = try await req.db.read { db in
            try Network.filter(Column("bridge") == body.interface).fetchOne(db)
        }
        if existing == nil {
            _ = try await NetworkService.create(
                CreateNetworkParams(
                    name: "Bridged (\(body.interface))",
                    mode: "bridged",
                    bridge: body.interface,
                    macAddress: nil,
                    dnsServer: nil,
                ),
                db: req.db,
            )
        }

        return BridgeResponse(success: true, message: nil)
    }

    @Sendable
    func skipBridge(req: Request) async throws -> BridgeResponse {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }
        return BridgeResponse(success: true, message: nil)
    }

    // MARK: - Repository Sync

    /// Tracks in-memory sync progress for the setup wizard
    private static let syncState = SyncProgressState()

    final class SyncProgressState: @unchecked Sendable {
        private let lock = NSLock()
        private var _syncing = false
        private var _message = ""
        private var _done = false
        private var _error: String?
        private var _imageCount = 0
        private var _templateCount = 0

        var status: RepoSyncStatus {
            lock.withLock {
                RepoSyncStatus(
                    syncing: _syncing,
                    message: _message,
                    done: _done,
                    error: _error,
                    imageCount: _imageCount,
                    templateCount: _templateCount,
                )
            }
        }

        func start() {
            lock.withLock {
                _syncing = true
                _done = false
                _error = nil
                _message = "Starting..."
            }
        }
        func update(message: String) {
            lock.withLock { _message = message }
        }
        func finish(images: Int, templates: Int) {
            lock.withLock {
                _syncing = false
                _done = true
                _imageCount = images
                _templateCount = templates
            }
        }
        func fail(_ error: String) {
            lock.withLock {
                _syncing = false
                _done = true
                _error = error
            }
        }
    }

    struct RepoSyncStatus: Content {
        let syncing: Bool
        let message: String
        let done: Bool
        let error: String?
        let imageCount: Int
        let templateCount: Int
    }

    @Sendable
    func syncRepositories(req: Request) async throws -> RepoSyncStatus {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }

        let state = Self.syncState
        let currentStatus = state.status
        guard !currentStatus.syncing else {
            return currentStatus
        }

        state.start()

        // Run sync in background so the request returns immediately
        Task {
            do {
                let imageCount = try await Seeder.syncBuiltInRepositories { message in
                    state.update(message: message)
                }
                state.update(message: "Syncing templates...")
                let templateCount = try await Seeder.syncBuiltInTemplates { message in
                    state.update(message: message)
                }
                state.finish(images: imageCount, templates: templateCount)
            } catch {
                state.fail(error.localizedDescription)
            }
        }

        return state.status
    }

    @Sendable
    func repositorySyncStatus(req: Request) async throws -> RepoSyncStatus {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }
        return Self.syncState.status
    }

    // MARK: - Complete

    struct CompleteResponse: Content {
        let success: Bool
        let token: String?
    }

    @Sendable
    func complete(req: Request) async throws -> CompleteResponse {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }

        // Fetch the admin user (first user with a password set)
        let admin = try await req.db.read { db in
            try User.filter(User.Columns.password != "").fetchOne(db)
        }
        guard let admin else {
            throw Abort(.badRequest, reason: "Admin user must be created before completing setup")
        }

        // Generate a JWT so the frontend can auto-login
        let payload = UserPayload(
            sub: .init(value: admin.id),
            username: admin.username,
            exp: .init(value: Date().addingTimeInterval(2 * 60 * 60))
        )
        let token = try await keys.sign(payload)

        setupMiddleware.markComplete()

        return CompleteResponse(success: true, token: token)
    }
}
