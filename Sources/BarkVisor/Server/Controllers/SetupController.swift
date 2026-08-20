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
        /// Shared identity landed after a pairing join (admin exists). A receipt
        /// alone is not enough — applyTrust persists it before pin / identity.
        let joined: Bool
    }

    /// Resume join-ready only after identity is complete. A pairing receipt can
    /// exist after a failed applyTrust; finishSetup then has no admin and no Back.
    static func shouldReportJoined(hasReceipt: Bool, hasAdmin: Bool) -> Bool {
        hasReceipt && hasAdmin
    }

    @Sendable
    func getStatus(req: Request) async throws -> StatusResponse {
        let hasAdmin = try await req.db.read { db in
            try User.filter(User.Columns.password != "").fetchCount(db) > 0
        }
        return StatusResponse(
            complete: setupMiddleware.isSetupComplete,
            joined: Self.shouldReportJoined(
                hasReceipt: PairingService.hasPairedReceipt(dataDir: Config.dataDir),
                hasAdmin: hasAdmin,
            ),
        )
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
        let records = try await req.db.read { db in
            try BridgeRecord.fetchAll(db)
        }
        return HostInfoService.listInterfaceSnapshots(
            bridgeStatusByInterface: HostBridgeFactsService.statusByInterface(records: records),
        ).map {
            InterfaceResponse(
                name: $0.name,
                displayName: $0.displayName,
                ipAddress: $0.ipAddress,
                bridgeStatus: $0.bridgeStatus,
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
        guard PlatformCapabilities.supportsManagedBridgeDaemon else {
            throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
        }
        let body = try req.content.decode(BridgeRequest.self)
        do {
            try await PrivilegeService.shared.installBridge(interface: body.interface)
        } catch {
            let msg = error.localizedDescription
            // Bridge already configured is not an error during setup
            if !msg.contains("already exists") {
                return BridgeResponse(success: false, message: msg)
            }
        }

        // Sync bridge state into the DB immediately
        await BridgeSyncService.syncOnce(db: req.db)
        // Setup-only: swallow already-exists above; shared helper creates the network row.
        _ = try await NetworkService.ensureBridgedNetwork(for: body.interface, db: req.db)

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
            exp: .init(value: Date().addingTimeInterval(2 * 60 * 60)),
        )
        let token = try await keys.sign(payload)

        setupMiddleware.markComplete()

        return CompleteResponse(success: true, token: token)
    }
}
