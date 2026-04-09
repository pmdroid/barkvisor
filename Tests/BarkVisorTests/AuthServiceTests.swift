import GRDB
import XCTest
@testable import BarkVisorCore

private struct TestPasswordHasher: PasswordHasher {
    func hash(_ password: String) throws -> String {
        "hashed:\(password)"
    }

    func verify(_ password: String, against hash: String) throws -> Bool {
        hash == "hashed:\(password)"
    }
}

final class AuthServiceTests: XCTestCase {
    private var dbPool: DatabasePool?
    private var tmpDir: URL?
    private let hasher = TestPasswordHasher()

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("test.sqlite").path
        dbPool = try DatabasePool(path: dbPath)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(dbPool)

        // Seed a user with password "testpass10"
        try dbPool.write { db in
            let user = User(
                id: "user-1", username: "admin",
                password: "hashed:testpass10",
                createdAt: "2025-01-01T00:00:00Z",
            )
            try user.insert(db)
        }
    }

    override func tearDown() {
        dbPool = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }
}
