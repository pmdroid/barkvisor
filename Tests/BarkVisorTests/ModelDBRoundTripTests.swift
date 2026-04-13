import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

/// Tests for DB round-trips of models not covered by the existing DatabaseMigrationTests.
@Suite final class ModelDBRoundTripTests {
    private let dbPool: DatabaseQueue

    init() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(queue)
        dbPool = queue
    }

    // MARK: - User

    @Test func userRoundTrip() throws {
        let user = User(
            id: "u1", username: "alice", password: "hash123", createdAt: "2025-01-01T00:00:00Z",
        )
        try dbPool.write { db in try user.insert(db) }
        let fetched = try dbPool.read { db in try User.fetchOne(db, key: "u1") }
        #expect(fetched?.username == "alice")
    }

    @Test func userUniqueUsername() throws {
        try dbPool.write { db in
            try User(id: "u1", username: "alice", password: "h1", createdAt: "2025-01-01T00:00:00Z")
                .insert(db)
        }
        #expect(throws: (any Error).self) {
            try self.dbPool.write { db in
                try User(id: "u2", username: "alice", password: "h2", createdAt: "2025-01-01T00:00:00Z")
                    .insert(db)
            }
        }
    }

    // MARK: - AppSetting

    @Test func appSettingRoundTrip() throws {
        let setting = AppSetting(key: "theme", value: "dark")
        try dbPool.write { db in try setting.insert(db) }
        let fetched = try dbPool.read { db in try AppSetting.fetchOne(db, key: "theme") }
        #expect(fetched?.value == "dark")
    }

    // MARK: - BridgeRecord

    @Test func bridgeRecordRoundTrip() throws {
        let bridge = BridgeRecord(
            id: nil,
            interface: "en0",
            socketPath: "/tmp/sock",
            plistExists: true,
            daemonRunning: false,
            status: "installed",
            updatedAt: "2025-01-01T00:00:00Z",
        )
        try dbPool.write { db in try bridge.insert(db) }
        let fetched = try dbPool.read { db in
            try BridgeRecord.filter(Column("interface") == "en0").fetchOne(db)
        }
        #expect(fetched?.interface == "en0")
        #expect(fetched?.plistExists == true)
        #expect(fetched?.daemonRunning == false)
        #expect(fetched?.id != nil)
    }

    // MARK: - SSHKey

    @Test func sshKeyRoundTrip() throws {
        let key = SSHKey(
            id: "k1",
            name: "My Key",
            publicKey: "ssh-ed25519 AAAA user@host",
            fingerprint: "SHA256:abc",
            keyType: "ssh-ed25519",
            isDefault: true,
            createdAt: "2025-01-01T00:00:00Z",
        )
        try dbPool.write { db in try key.insert(db) }
        let fetched = try dbPool.read { db in try SSHKey.fetchOne(db, key: "k1") }
        #expect(fetched?.name == "My Key")
        #expect(fetched?.isDefault == true)
        #expect(fetched?.keyType == "ssh-ed25519")
    }

    // MARK: - APIKey

    @Test func apiKeyRoundTrip() throws {
        // Need a user first for FK
        try dbPool.write { db in
            try User(id: "u1", username: "admin", password: "h", createdAt: "2025-01-01T00:00:00Z")
                .insert(db)
        }

        let key = APIKey(
            id: "ak1",
            name: "Test",
            keyHash: "hash",
            keyPrefix: "barkvisor_abcde",
            userId: "u1",
            expiresAt: nil,
            lastUsedAt: nil,
            createdAt: "2025-01-01T00:00:00Z",
        )
        try dbPool.write { db in try key.insert(db) }
        let fetched = try dbPool.read { db in try APIKey.fetchOne(db, key: "ak1") }
        #expect(fetched?.name == "Test")
        #expect(fetched?.userId == "u1")
        #expect(fetched?.keyPrefix == "barkvisor_abcde")
    }

    @Test func apiKeyCascadeDeleteOnUserDelete() throws {
        try dbPool.write { db in
            try User(id: "u1", username: "admin", password: "h", createdAt: "2025-01-01T00:00:00Z")
                .insert(db)
            try APIKey(
                id: "ak1",
                name: "Key",
                keyHash: "h",
                keyPrefix: "p",
                userId: "u1",
                expiresAt: nil,
                lastUsedAt: nil,
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }

        // Delete user — API key should cascade
        try dbPool.write { db in try User.deleteOne(db, key: "u1") }
        let key = try dbPool.read { db in try APIKey.fetchOne(db, key: "ak1") }
        #expect(key == nil, "API key should be cascade-deleted with user")
    }

    // MARK: - AuditEntry

    @Test func auditEntryAutoIncrementID() throws {
        try dbPool.write { db in
            let entry = AuditEntry(
                id: nil,
                timestamp: "2025-01-01T00:00:00Z",
                userId: nil,
                username: nil,
                action: "test",
                resourceType: nil,
                resourceId: nil,
                resourceName: nil,
                detail: nil,
                authMethod: nil,
                apiKeyId: nil,
            )
            try entry.insert(db)
        }
        let fetched = try dbPool.read { db in try AuditEntry.fetchAll(db) }
        #expect(fetched.count == 1)
        #expect(fetched.first?.id != nil)
    }

    // MARK: - ImageRepository

    @Test func imageRepositoryRoundTrip() throws {
        let repo = ImageRepository(
            id: "repo-1", name: "Official", url: "https://example.com/repo.json",
            isBuiltIn: true, repoType: "both", lastSyncedAt: nil, lastError: nil,
            syncStatus: "idle", createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )
        try dbPool.write { db in try repo.insert(db) }
        let fetched = try dbPool.read { db in try ImageRepository.fetchOne(db, key: "repo-1") }
        #expect(fetched?.name == "Official")
        #expect(fetched?.repoType == "both")
        #expect(fetched?.syncStatus == "idle")
    }

    // MARK: - RepositoryImage

    @Test func repositoryImageRoundTrip() throws {
        // Need repository first
        try dbPool.write { db in
            try ImageRepository(
                id: "repo-1", name: "Test", url: "https://example.com",
                isBuiltIn: false, repoType: "images", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }

        let image = RepositoryImage(
            id: "ri-1", repositoryId: "repo-1", slug: "ubuntu-24.04",
            name: "Ubuntu 24.04", description: "LTS release",
            imageType: "cloud-image", arch: "arm64", version: "24.04",
            downloadUrl: "https://example.com/ubuntu.img", sizeBytes: 1_000_000,
        )
        try dbPool.write { db in try image.insert(db) }
        let fetched = try dbPool.read { db in try RepositoryImage.fetchOne(db, key: "ri-1") }
        #expect(fetched?.slug == "ubuntu-24.04")
        #expect(fetched?.arch == "arm64")
    }

    // MARK: - VMImage

    @Test func vmImageRoundTrip() throws {
        let image = VMImage(
            id: "img-1", name: "Ubuntu", imageType: "cloud-image",
            arch: "arm64", path: "/data/images/test.img", sizeBytes: 500_000,
            status: "ready", error: nil, sourceUrl: "https://example.com/test.img",
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )
        try dbPool.write { db in try image.insert(db) }
        let fetched = try dbPool.read { db in try VMImage.fetchOne(db, key: "img-1") }
        #expect(fetched?.name == "Ubuntu")
        #expect(fetched?.status == "ready")
    }

    // MARK: - TusUpload (cascade)

    @Test func tusUploadCascadeOnImageDelete() throws {
        try dbPool.write { db in
            try VMImage(
                id: "img-1", name: "Test", imageType: "iso", arch: "arm64",
                path: nil, sizeBytes: nil, status: "downloading", error: nil,
                sourceUrl: nil, createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
            ).insert(db)
            try TusUpload(
                id: "tus-1", imageId: "img-1", offset: 0, length: 1_000,
                metadata: "test", chunkPath: "/tmp/chunk", createdAt: "2025-01-01T00:00:00Z",
                updatedAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }

        try dbPool.write { db in try VMImage.deleteOne(db, key: "img-1") }
        let upload = try dbPool.read { db in try TusUpload.fetchOne(db, key: "tus-1") }
        #expect(upload == nil, "TusUpload should cascade-delete with image")
    }

    // MARK: - GuestInfoRecord

    @Test func guestInfoRoundTrip() throws {
        // Need disk and VM first
        try dbPool.write { db in
            try Disk(
                id: "d1",
                name: "boot",
                path: "/tmp/d1.qcow2",
                sizeBytes: 1_000_000,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
            try VM(
                id: "vm-1", name: "test", vmType: "linux-arm64", state: "stopped",
                cpuCount: 2, memoryMb: 1_024, bootDiskId: "d1", isoId: nil, networkId: nil,
                cloudInitPath: nil, vncPort: nil, description: nil, bootOrder: "cd",
                displayResolution: "1280x800", additionalDiskIds: nil, uefi: true,
                tpmEnabled: false, macAddress: "52:54:00:12:34:56", sharedPaths: nil,
                portForwards: nil, autoCreated: false, pendingChanges: false,
                createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }

        let guest = GuestInfoRecord(
            vmId: "vm-1", hostname: "myhost", osName: "Ubuntu",
            osVersion: "24.04", osId: "ubuntu", kernelVersion: "6.8",
            kernelRelease: "6.8.0-generic", machine: "aarch64",
            timezone: "UTC", timezoneOffset: 0, ipAddresses: "[\"192.168.1.5\"]",
            macAddress: "52:54:00:12:34:56", users: "[]", filesystems: "[]",
            updatedAt: "2025-01-01T00:00:00Z",
        )
        try dbPool.write { db in try guest.insert(db) }
        let fetched = try dbPool.read { db in try GuestInfoRecord.fetchOne(db, key: "vm-1") }
        #expect(fetched?.hostname == "myhost")
        #expect(fetched?.osName == "Ubuntu")
    }

    @Test func guestInfoCascadeOnVMDelete() throws {
        try dbPool.write { db in
            try Disk(
                id: "d1",
                name: "boot",
                path: "/tmp/d2.qcow2",
                sizeBytes: 1_000_000,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
            try VM(
                id: "vm-1", name: "test2", vmType: "linux-arm64", state: "stopped",
                cpuCount: 2, memoryMb: 1_024, bootDiskId: "d1", isoId: nil, networkId: nil,
                cloudInitPath: nil, vncPort: nil, description: nil, bootOrder: "cd",
                displayResolution: "1280x800", additionalDiskIds: nil, uefi: true,
                tpmEnabled: false, macAddress: "52:54:00:12:34:57", sharedPaths: nil,
                portForwards: nil, autoCreated: false, pendingChanges: false,
                createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
            ).insert(db)
            try GuestInfoRecord(
                vmId: "vm-1", hostname: "h", osName: nil, osVersion: nil, osId: nil,
                kernelVersion: nil, kernelRelease: nil, machine: nil, timezone: nil,
                timezoneOffset: nil, ipAddresses: nil, macAddress: nil, users: nil,
                filesystems: nil, updatedAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }

        try dbPool.write { db in try VM.deleteOne(db, key: "vm-1") }
        let guest = try dbPool.read { db in try GuestInfoRecord.fetchOne(db, key: "vm-1") }
        #expect(guest == nil, "GuestInfo should cascade-delete with VM")
    }

    // MARK: - VMTemplate

    @Test func vmTemplateRoundTrip() throws {
        let template = VMTemplate(
            id: "t1", slug: "ubuntu-server", name: "Ubuntu Server",
            description: "A server template", category: "server", icon: "ubuntu",
            imageSlug: "ubuntu-24.04", cpuCount: 4, memoryMB: 4_096, diskSizeGB: 20,
            portForwards: nil, networkMode: "nat", inputs: "[]",
            userDataTemplate: "#cloud-config", isBuiltIn: true, repositoryId: nil,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )
        try dbPool.write { db in try template.insert(db) }
        let fetched = try dbPool.read { db in try VMTemplate.fetchOne(db, key: "t1") }
        #expect(fetched?.slug == "ubuntu-server")
        #expect(fetched?.cpuCount == 4)
        #expect(fetched?.memoryMB == 4_096)
    }
}
