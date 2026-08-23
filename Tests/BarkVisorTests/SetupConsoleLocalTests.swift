import Foundation
import GRDB
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Setup console-local (PAS-276)")
struct SetupConsoleLocalTests {
    private func isolatedPool() throws -> (URL, DatabasePool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "setup-local-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return (dir, pool)
    }

    private func expectForbidden(_ peer: String?) {
        do {
            try SetupMiddleware.requireConsoleLocalClient(peer)
            Issue.record("expected forbidden for peer \(peer ?? "nil")")
        } catch let error as Abort {
            #expect(error.status == .forbidden)
            #expect(error.reason == "Setup is limited to this Device")
        } catch {
            Issue.record("expected Abort, got \(error)")
        }
    }

    @Test func `setup API path matches wizard routes only`() {
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/status"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/admin"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/complete"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/bridge/skip"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/repositories/sync"))
        #expect(!SetupMiddleware.isSetupAPIPath("/api/setupfoo"))
        #expect(!SetupMiddleware.isSetupAPIPath("/api/pairing/join"))
        #expect(!SetupMiddleware.isSetupAPIPath("/api/health"))
        #expect(SetupController.mutatingSetupPaths.contains("/api/setup/admin"))
        #expect(SetupController.mutatingSetupPaths.contains("/api/setup/complete"))
        for path in SetupController.mutatingSetupPaths {
            #expect(SetupMiddleware.isSetupAPIPath(path))
        }
    }

    @Test func `middleware rejects LAN and CGNAT peers`() throws {
        try SetupMiddleware.requireConsoleLocalClient("127.0.0.1")
        try SetupMiddleware.requireConsoleLocalClient("127.1")
        try SetupMiddleware.requireConsoleLocalClient("::1")
        try SetupMiddleware.requireConsoleLocalClient("[::1]")
        try SetupMiddleware.requireConsoleLocalClient("::ffff:127.0.0.1")
        try SetupMiddleware.requireConsoleLocalClient("localhost")
        expectForbidden("192.168.1.10")
        expectForbidden("10.0.0.5")
        expectForbidden("172.16.0.9")
        expectForbidden("100.64.0.1")
        expectForbidden("8.8.8.8")
        expectForbidden(nil)
        expectForbidden("")
    }

    @Test func `pairing join leaves setup open and LAN still cannot finish it`() throws {
        let (dir, pool) = try isolatedPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = SetupMiddleware(dbPool: pool)
        #expect(!setup.isSetupComplete)
        // PairingController.join must not call markComplete; the wizard
        // still needs bridge / catalog steps on this Device.
        expectForbidden("192.168.1.10")
        expectForbidden("10.0.0.5")
        try SetupMiddleware.requireConsoleLocalClient("127.0.0.1")
        for path in SetupController.mutatingSetupPaths {
            #expect(SetupMiddleware.isSetupAPIPath(path))
            #expect(throws: Abort.self) {
                try SetupMiddleware.requireConsoleLocalClient("192.168.1.10")
            }
        }
        setup.markComplete()
        #expect(setup.isSetupComplete)
        expectForbidden("192.168.1.10")
    }

    @Test func `empty-password setup keeps stored role`() throws {
        let (dir, pool) = try isolatedPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        try pool.write { db in
            try User(
                id: "u-inf",
                username: "agent",
                password: "",
                createdAt: "2026-01-01T00:00:00Z",
                role: UserRole.inference.rawValue,
            ).insert(db)
            try SetupController.setPasswordIfEmpty(username: "agent", hash: "hashed-pw", db: db)
            let row = try User.filter(User.Columns.username == "agent").fetchOne(db)
            #expect(row?.password == "hashed-pw")
            #expect(row?.role == UserRole.inference.rawValue)
        }
        try pool.write { db in
            try User(
                id: "u-adm",
                username: "pascal",
                password: "",
                createdAt: "2026-01-01T00:00:00Z",
                role: UserRole.admin.rawValue,
            ).insert(db)
            try SetupController.setPasswordIfEmpty(username: "pascal", hash: "hashed-admin", db: db)
            let row = try User.filter(User.Columns.username == "pascal").fetchOne(db)
            #expect(row?.password == "hashed-admin")
            #expect(row?.role == UserRole.admin.rawValue)
        }
    }

    @Test func `setup controller rejects requests without a console-local peer`() async throws {
        var env = Environment(name: "testing", arguments: ["barkvisor-test"])
        env.commandInput = CommandInput(arguments: ["barkvisor-test"])
        let app = try await Application.make(env)
        app.logger.logLevel = .error
        do {
            let req = Request(
                application: app,
                method: .POST,
                url: URI(string: "/api/setup/admin"),
                on: app.eventLoopGroup.next(),
            )
            do {
                try SetupController.requireConsoleLocal(req)
                Issue.record("expected forbidden when Request has no peer")
            } catch let error as Abort {
                #expect(error.status == .forbidden)
            } catch {
                Issue.record("expected Abort, got \(error)")
            }
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}
