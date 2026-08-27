import Foundation
import GRDB
import Testing
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

    @Test func `setup is unfinished after admin until library or join`() {
        #expect(
            !SetupController.isSetupFinished(
                middlewareComplete: true,
                joined: false,
                libraryChosen: false,
            ),
        )
        #expect(
            SetupController.isSetupFinished(
                middlewareComplete: true,
                joined: false,
                libraryChosen: true,
            ),
        )
        #expect(
            SetupController.isSetupFinished(
                middlewareComplete: true,
                joined: true,
                libraryChosen: false,
            ),
        )
        #expect(
            !SetupController.isSetupFinished(
                middlewareComplete: false,
                joined: false,
                libraryChosen: true,
            ),
        )
    }

    @Test func `setup API path matches wizard routes only`() {
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/status"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/admin"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/complete"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/bridge/skip"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/repositories/sync"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/library"))
        #expect(SetupMiddleware.isSetupAPIPath("/api/setup/browse"))
        #expect(!SetupMiddleware.isSetupAPIPath("/api/setupfoo"))
        #expect(!SetupMiddleware.isSetupAPIPath("/api/pairing/join"))
        #expect(!SetupMiddleware.isSetupAPIPath("/api/health"))
        #expect(SetupController.mutatingSetupPaths.contains("/api/setup/admin"))
        #expect(SetupController.mutatingSetupPaths.contains("/api/setup/library"))
        #expect(SetupController.mutatingSetupPaths.contains("/api/setup/complete"))
        #expect(!SetupController.mutatingSetupPaths.contains("/api/setup/status"))
        #expect(!SetupController.mutatingSetupPaths.contains("/api/setup/browse"))
        for path in SetupController.mutatingSetupPaths {
            #expect(SetupMiddleware.isSetupAPIPath(path))
        }
    }

    @Test func `pairing join closes setup after shared identity lands`() throws {
        let (dir, pool) = try isolatedPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = SetupMiddleware(dbPool: pool)
        #expect(!setup.isSetupComplete)
        try pool.write { db in
            try User(
                id: "u-join",
                username: "admin",
                password: "hashed-from-home",
                createdAt: "2026-01-01T00:00:00Z",
                role: UserRole.admin.rawValue,
            ).insert(db)
        }
        #expect(!setup.isSetupComplete)
        setup.refreshFromDatabase()
        #expect(setup.isSetupComplete)
    }

    @Test func `refreshFromDatabase keeps complete when sqlite read fails`() throws {
        let (dir, pool) = try isolatedPool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = SetupMiddleware(dbPool: pool)
        setup.markComplete()
        try pool.close()
        setup.refreshFromDatabase()
        #expect(setup.isSetupComplete)
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
}
