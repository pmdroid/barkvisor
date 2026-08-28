import BarkVisorCore
import Foundation
import GRDB
import JWTKit
import Vapor

/// Handles the web-based onboarding wizard. No JWT. Mutating steps 404 after setup.
struct SetupController: RouteCollection {
    let setupMiddleware: SetupMiddleware
    let keys: JWTKeyCollection

    func boot(routes: any RoutesBuilder) throws {
        let setup = routes.grouped("api", "setup")
        setup.get("status", use: getStatus)
        setup.post("admin", use: createAdmin)
        setup.post("passkeys", "register", "begin", use: passkeyRegisterBegin)
        setup.post("passkeys", "register", "finish", use: passkeyRegisterFinish)
        setup.get("interfaces", use: listInterfaces)
        setup.post("bridge", use: installBridge)
        setup.post("bridge", "skip", use: skipBridge)
        setup.post("repositories", "sync", use: syncRepositories)
        setup.get("repositories", "status", use: repositorySyncStatus)
        setup.get("library", use: getLibrary)
        setup.put("library", use: updateLibrary)
        setup.get("browse", use: browseDirectory)
        setup.post("complete", use: complete)
    }

    static let mutatingSetupPaths = [
        "/api/setup/admin",
        "/api/setup/passkeys/register/begin",
        "/api/setup/passkeys/register/finish",
        "/api/setup/library",
        "/api/setup/complete",
    ]

    // MARK: - Status

    struct StatusResponse: Content {
        let complete: Bool
        /// Shared identity landed after a pairing join (admin exists). A receipt
        /// alone is not enough — applyTrust persists it before pin / identity.
        let joined: Bool
        let admin: Bool
    }

    /// Resume join-ready only after identity is complete. A pairing receipt can
    /// exist after a failed applyTrust; finishSetup then has no admin and no Back.
    static func shouldReportJoined(hasReceipt: Bool, hasAdmin: Bool) -> Bool {
        hasReceipt && hasAdmin
    }

    static func isSetupFinished(
        middlewareComplete: Bool,
        joined: Bool,
        libraryChosen: Bool,
    ) -> Bool {
        middlewareComplete && (joined || libraryChosen)
    }

    @Sendable
    func getStatus(req: Request) async throws -> StatusResponse {
        let snapshot = try await req.db.read { db in
            try (
                hasAdmin: User.hasProvisionedAdmin(db),
                libraryChosen: LibrarySettings.hasExplicitDirectory(from: db),
            )
        }
        let joined = Self.shouldReportJoined(
            hasReceipt: PairingService.hasPairedReceipt(dataDir: Config.dataDir),
            hasAdmin: snapshot.hasAdmin,
        )
        return StatusResponse(
            complete: Self.isSetupFinished(
                middlewareComplete: setupMiddleware.isSetupComplete,
                joined: joined,
                libraryChosen: snapshot.libraryChosen,
            ),
            joined: joined,
            admin: snapshot.hasAdmin,
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
                try Self.setPasswordIfEmpty(
                    username: body.username,
                    hash: hash,
                    db: db,
                )
            } else {
                let existingCount = try User.fetchCount(db)
                let user = User(
                    id: UUID().uuidString,
                    username: body.username,
                    password: hash,
                    createdAt: iso8601.string(from: Date()),
                    role: UserRolePolicy.roleForNewUser(existingUserCount: existingCount).rawValue,
                )
                try user.insert(db)
            }
        }

        return AdminResponse(success: true)
    }

    @Sendable
    func passkeyRegisterBegin(req: Request) async throws -> Response {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }
        let body = (try? req.content.decode(PasskeyRegisterBeginRequest.self)) ?? PasskeyRegisterBeginRequest()
        let user = try await req.db.write { db in
            try Self.ensureSetupAdmin(db: db)
        }
        let rp = try PasskeyService.relyingParty(
            hostHeader: req.headers[.host].first,
            originHeader: req.headers[.origin].first,
        )
        let begin = try await PasskeyService.beginRegister(
            user: user, name: body.name, rp: rp, db: req.db,
        )
        var headers = HTTPHeaders()
        headers.contentType = .json
        return try Response(status: .ok, headers: headers, body: .init(data: begin.responseBody()))
    }

    @Sendable
    func passkeyRegisterFinish(req: Request) async throws -> PasskeyCredentialResponse {
        guard !setupMiddleware.isSetupComplete else {
            throw Abort(.notFound)
        }
        let raw = try await req.body.collect(upTo: 1 << 20)
        let data = Data(buffer: raw)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = obj["sessionId"] as? String,
              !sessionId.isEmpty,
              let credential = obj["credential"],
              JSONSerialization.isValidJSONObject(credential)
        else {
            throw BarkVisorError.badRequest("Invalid passkey credential")
        }
        let user = try await req.db.write { db in
            try Self.ensureSetupAdmin(db: db)
        }
        let rp = try PasskeyService.relyingParty(
            hostHeader: req.headers[.host].first,
            originHeader: req.headers[.origin].first,
        )
        let credentialJSON = try JSONSerialization.data(withJSONObject: credential)
        return try await PasskeyService.finishRegister(
            sessionId: sessionId,
            credentialJSON: credentialJSON,
            name: obj["name"] as? String,
            userId: user.id,
            rp: rp,
            db: req.db,
        )
    }

    static func ensureSetupAdmin(db: Database) throws -> User {
        if let existing = try User.filter(User.Columns.username == "admin").fetchOne(db) {
            return existing
        }
        if let existing = try User.fetchOne(db) {
            return existing
        }
        let user = User(
            id: UUID().uuidString,
            username: "admin",
            password: "",
            createdAt: iso8601.string(from: Date()),
            role: UserRolePolicy.roleForNewUser(existingUserCount: 0).rawValue,
        )
        try user.insert(db)
        return user
    }

    /// Empty-password row: set the hash only. Setup must not overwrite `role`
    /// (an inference user with no password must not become admin).
    static func setPasswordIfEmpty(username: String, hash: String, db: Database) throws {
        try db.execute(
            sql: """
            UPDATE users SET password = ?
            WHERE username = ? AND password = ''
            """,
            arguments: [hash, username],
        )
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
        if try await setupFinished(req: req) {
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
        if try await setupFinished(req: req) {
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
        if try await setupFinished(req: req) {
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
        if try await setupFinished(req: req) {
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
        if try await setupFinished(req: req) {
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
        if try await setupFinished(req: req) {
            throw Abort(.notFound)
        }

        let admin = try await req.db.read { db in
            try User.fetchProvisionedAdmin(db)
        }
        guard let admin else {
            throw Abort(.badRequest, reason: "Add a passkey before completing setup")
        }

        let libraryChosen = try await req.db.read { db in
            try LibrarySettings.hasExplicitDirectory(from: db)
        }
        guard libraryChosen else {
            throw Abort(.badRequest, reason: "Library folder must be chosen before completing setup")
        }

        // Generate a JWT so the frontend can auto-login
        let payload = UserPayload(
            sub: .init(value: admin.id),
            username: admin.username,
            exp: .init(value: Date().addingTimeInterval(2 * 60 * 60)),
            role: admin.userRole.rawValue,
        )
        let token = try await keys.sign(payload)

        setupMiddleware.markComplete()

        return CompleteResponse(success: true, token: token)
    }

    @Sendable
    func getLibrary(req: Request) async throws -> LibrarySettingsResponse {
        if try await setupFinished(req: req) {
            throw Abort(.notFound)
        }
        return try await LibrarySettingsController.load(req: req)
    }

    @Sendable
    func updateLibrary(req: Request) async throws -> LibrarySettingsResponse {
        if try await setupFinished(req: req) {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(LibrarySettingsRequest.self)
        return try await LibrarySettingsController.apply(
            req: req,
            body: LibrarySettingsRequest(
                imageDirectory: body.imageDirectory,
            ),
        )
    }

    @Sendable
    func browseDirectory(req: Request) async throws -> [BrowseEntry] {
        if try await setupFinished(req: req) {
            throw Abort(.notFound)
        }
        return try await SystemHostController.listDirectory(req: req)
    }

    private func setupFinished(req: Request) async throws -> Bool {
        let snapshot = try await req.db.read { db in
            try (
                hasAdmin: User.hasProvisionedAdmin(db),
                libraryChosen: LibrarySettings.hasExplicitDirectory(from: db),
            )
        }
        return Self.isSetupFinished(
            middlewareComplete: setupMiddleware.isSetupComplete,
            joined: Self.shouldReportJoined(
                hasReceipt: PairingService.hasPairedReceipt(dataDir: Config.dataDir),
                hasAdmin: snapshot.hasAdmin,
            ),
            libraryChosen: snapshot.libraryChosen,
        )
    }
}
