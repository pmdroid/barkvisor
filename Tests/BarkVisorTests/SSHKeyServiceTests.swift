import GRDB
import XCTest
@testable import BarkVisorCore

final class SSHKeyServiceTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var tmpDir: URL!

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
    }

    override func tearDown() {
        dbPool = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - extractKeyType

    func testExtractKeyTypeRSA() {
        XCTAssertEqual(SSHKeyService.extractKeyType("ssh-rsa AAAA user@host"), "ssh-rsa")
    }

    func testExtractKeyTypeEd25519() {
        XCTAssertEqual(SSHKeyService.extractKeyType("ssh-ed25519 AAAA user@host"), "ssh-ed25519")
    }

    func testExtractKeyTypeEmpty() {
        XCTAssertEqual(SSHKeyService.extractKeyType(""), "unknown")
    }

    // MARK: - computeFingerprint

    func testComputeFingerprintValid() {
        // Use a valid base64 blob (48 bytes = valid ed25519 key blob)
        let key =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBRKHBnYEfAPOgGdGMbgMSxIwffOG6Uj8mGYmNGMWsT user@host"
        let fp = SSHKeyService.computeFingerprint(key)
        XCTAssertTrue(fp.hasPrefix("SHA256:"), "Fingerprint should start with SHA256: but got \(fp)")
        XCTAssertFalse(fp.contains("="), "Fingerprint should not contain padding")
    }

    func testComputeFingerprintInvalidReturnsUnknown() {
        XCTAssertEqual(SSHKeyService.computeFingerprint("not a key"), "unknown")
        XCTAssertEqual(SSHKeyService.computeFingerprint("ssh-rsa"), "unknown")
    }

    // MARK: - CRUD

    func testCreateSSHKey() async throws {
        let key = try await SSHKeyService.create(
            name: "My Key",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBRKHBnYEfAPOgGdGMbgMSxIwffOG6Uj8mGYmNGMWsT user@host",
            db: dbPool,
        )

        XCTAssertEqual(key.name, "My Key")
        XCTAssertEqual(key.keyType, "ssh-ed25519")
        XCTAssertTrue(key.isDefault, "First key should automatically become the default")
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
    }

    func testCreateSSHKeyEmptyNameRejected() async {
        do {
            _ = try await SSHKeyService.create(
                name: "  ", publicKey: "ssh-rsa AAAA user@host", db: dbPool,
            )
            XCTFail("Should reject empty name")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 400)
        } catch {
            XCTFail("Wrong error type")
        }
    }

    func testFirstKeyBecomesDefault() async throws {
        let key1 = try await SSHKeyService.create(
            name: "Key1",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAx user@host",
            db: dbPool,
        )
        XCTAssertTrue(key1.isDefault, "First key should automatically become the default")

        let key2 = try await SSHKeyService.create(
            name: "Key2",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAy user@host",
            db: dbPool,
        )
        XCTAssertFalse(key2.isDefault, "Second key should not become default")
    }

    func testSetDefault() async throws {
        let key1 = try await SSHKeyService.create(
            name: "Key1",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAx user@host",
            db: dbPool,
        )
        let key2 = try await SSHKeyService.create(
            name: "Key2",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAy user@host",
            db: dbPool,
        )

        let updated = try await SSHKeyService.setDefault(id: key2.id, db: dbPool)
        XCTAssertTrue(updated.isDefault)

        // key1 should no longer be default
        let keys = try await SSHKeyService.list(db: dbPool)
        let k1 = keys.first(where: { $0.id == key1.id })
        let k2 = keys.first(where: { $0.id == key2.id })
        XCTAssertEqual(k1?.isDefault, false)
        XCTAssertEqual(k2?.isDefault, true)
    }

    func testSetDefaultNonExistent() async {
        do {
            _ = try await SSHKeyService.setDefault(id: "fake", db: dbPool)
            XCTFail("Should throw notFound")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 404)
        } catch {
            XCTFail("Wrong error type")
        }
    }

    func testDeleteSSHKey() async throws {
        let key = try await SSHKeyService.create(
            name: "ToDelete",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAz user@host",
            db: dbPool,
        )
        try await SSHKeyService.delete(id: key.id, db: dbPool)

        let keys = try await SSHKeyService.list(db: dbPool)
        XCTAssertTrue(keys.isEmpty)
    }

    func testDeleteNonExistent() async {
        do {
            try await SSHKeyService.delete(id: "fake", db: dbPool)
            XCTFail("Should throw notFound")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 404)
        } catch {
            XCTFail("Wrong error type")
        }
    }

    func testListSSHKeys() async throws {
        _ = try await SSHKeyService.create(
            name: "A",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA user@host",
            db: dbPool,
        )
        _ = try await SSHKeyService.create(
            name: "B",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB user@host",
            db: dbPool,
        )

        let keys = try await SSHKeyService.list(db: dbPool)
        XCTAssertEqual(keys.count, 2)
    }
}
