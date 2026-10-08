import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct PasskeyPairingSetupTests {
    @Test func `passkey-only identity closes setup after join persistence`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let issuer = try DatabasePool(path: root.appendingPathComponent("issuer.sqlite").path)
        let joiner = try DatabasePool(path: root.appendingPathComponent("joiner.sqlite").path)
        try AppDatabase.makeMigrator().migrate(issuer)
        try AppDatabase.makeMigrator().migrate(joiner)
        let publicKey = Data("public-key".utf8)
        try issuer.write { db in
            try User(id: "admin-id", username: "admin", password: "", createdAt: "2026-01-01T00:00:00Z", role: "admin").insert(db)
            try PasskeyCredential(
                id: "pk-1", userId: "admin-id", credentialId: "cred-1", publicKey: publicKey,
                signCount: 3, name: "laptop", createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        let admin = try PairingService.loadAdminUser(db: issuer)
        let passkey = try PairingService.loadPasskey(db: issuer)
        #expect(admin?.passwordHash.isEmpty == true)
        #expect(passkey?.credentialId == "cred-1")
        try PairingService.upsertAdmin(#require(admin), passkey: passkey, db: joiner, now: Date())
        let provisioned = try joiner.read { try User.hasProvisionedAdmin($0) }
        let stored = try joiner.read { try PasskeyCredential.fetchCount($0) }
        #expect(provisioned)
        #expect(stored == 1)
    }
}
