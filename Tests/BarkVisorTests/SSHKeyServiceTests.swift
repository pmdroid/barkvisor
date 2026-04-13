import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite final class SSHKeyServiceTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - extractKeyType

    @Test func extractKeyTypeRSA() {
        #expect(SSHKeyService.extractKeyType("ssh-rsa AAAA user@host") == "ssh-rsa")
    }

    @Test func extractKeyTypeEd25519() {
        #expect(SSHKeyService.extractKeyType("ssh-ed25519 AAAA user@host") == "ssh-ed25519")
    }

    @Test func extractKeyTypeEmpty() {
        #expect(SSHKeyService.extractKeyType("") == "unknown")
    }

    // MARK: - computeFingerprint

    @Test func computeFingerprintValid() {
        // Use a valid base64 blob (48 bytes = valid ed25519 key blob)
        let key =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBRKHBnYEfAPOgGdGMbgMSxIwffOG6Uj8mGYmNGMWsT user@host"
        let fp = SSHKeyService.computeFingerprint(key)
        #expect(fp.hasPrefix("SHA256:"), "Fingerprint should start with SHA256: but got \(fp)")
        #expect(!fp.contains("="), "Fingerprint should not contain padding")
    }

    @Test func computeFingerprintInvalidReturnsUnknown() {
        #expect(SSHKeyService.computeFingerprint("not a key") == "unknown")
        #expect(SSHKeyService.computeFingerprint("ssh-rsa") == "unknown")
    }

    // MARK: - CRUD

    @Test func createSSHKey() async throws {
        let key = try await SSHKeyService.create(
            name: "My Key",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBRKHBnYEfAPOgGdGMbgMSxIwffOG6Uj8mGYmNGMWsT user@host",
            db: dbPool,
        )

        #expect(key.name == "My Key")
        #expect(key.keyType == "ssh-ed25519")
        #expect(key.isDefault, "First key should automatically become the default")
        #expect(key.fingerprint.hasPrefix("SHA256:"))
    }

    @Test func createSSHKeyEmptyNameRejected() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await SSHKeyService.create(
                name: "  ", publicKey: "ssh-rsa AAAA user@host", db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 400)
    }

    @Test func firstKeyBecomesDefault() async throws {
        let key1 = try await SSHKeyService.create(
            name: "Key1",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAx user@host",
            db: dbPool,
        )
        #expect(key1.isDefault, "First key should automatically become the default")

        let key2 = try await SSHKeyService.create(
            name: "Key2",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAy user@host",
            db: dbPool,
        )
        #expect(!key2.isDefault, "Second key should not become default")
    }

    @Test func setDefault() async throws {
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
        #expect(updated.isDefault)

        // key1 should no longer be default
        let keys = try await SSHKeyService.list(db: dbPool)
        let k1 = keys.first(where: { $0.id == key1.id })
        let k2 = keys.first(where: { $0.id == key2.id })
        #expect(k1?.isDefault == false)
        #expect(k2?.isDefault == true)
    }

    @Test func setDefaultNonExistent() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await SSHKeyService.setDefault(id: "fake", db: self.dbPool)
        }
        #expect(error?.httpStatus == 404)
    }

    @Test func deleteSSHKey() async throws {
        let key = try await SSHKeyService.create(
            name: "ToDelete",
            publicKey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAz user@host",
            db: dbPool,
        )
        try await SSHKeyService.delete(id: key.id, db: dbPool)

        let keys = try await SSHKeyService.list(db: dbPool)
        #expect(keys.isEmpty)
    }

    @Test func deleteNonExistent() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await SSHKeyService.delete(id: "fake", db: self.dbPool)
        }
        #expect(error?.httpStatus == 404)
    }

    @Test func listSSHKeys() async throws {
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
        #expect(keys.count == 2)
    }
}
