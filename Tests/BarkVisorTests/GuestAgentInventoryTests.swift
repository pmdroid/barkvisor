import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite("GuestAgentInventory")
struct GuestAgentInventoryTests {
    @Test func `guest-sync mismatch throws`() {
        #expect(throws: BarkVisorError.self) {
            try GuestAgentChannel.validateGuestSync(["return": 1], expected: 2)
        }
    }

    @Test func `guest-sync match is silent`() throws {
        try GuestAgentChannel.validateGuestSync(["return": 42], expected: 42)
        try GuestAgentChannel.validateGuestSync(["return": Int64(7)], expected: 7)
        try GuestAgentChannel.validateGuestSync([:], expected: 1)
    }

    @Test func `interfaces skip loopback and collect ipv4`() {
        let payload: [String: Any] = [
            "return": [
                [
                    "name": "lo",
                    "hardware-address": "00:00:00:00:00:00",
                    "ip-addresses": [
                        ["ip-address-type": "ipv4", "ip-address": "127.0.0.1"],
                    ],
                ],
                [
                    "name": "eth0",
                    "hardware-address": "52:54:00:12:34:56",
                    "ip-addresses": [
                        ["ip-address-type": "ipv4", "ip-address": "192.168.64.10"],
                        ["ip-address-type": "ipv6", "ip-address": "fd00::10"],
                    ],
                ],
            ],
        ]
        let parsed = GuestAgentInventory.parseNetworkInterfaces(payload)
        #expect(parsed.ips == ["192.168.64.10"])
        #expect(parsed.mac == "52:54:00:12:34:56")
    }

    @Test func `users and filesystems parse qga return`() {
        let users = GuestAgentInventory.parseGuestUsers([
            "return": [
                ["user": "alice", "login-time": 1_700_000_000.0],
                ["login-time": 1.0],
            ],
        ])
        #expect(users?.count == 1)
        #expect(users?.first?.name == "alice")

        let filesystems = GuestAgentInventory.parseGuestFilesystems([
            "return": [
                [
                    "mountpoint": "/",
                    "type": "ext4",
                    "name": "/dev/vda1",
                    "total-bytes": 1_024,
                    "used-bytes": 512,
                ],
            ],
        ])
        #expect(filesystems?.first?.mountpoint == "/")
        #expect(filesystems?.first?.totalBytes == 1_024)
        #expect(filesystems?.first?.usedBytes == 512)
    }

    @Test func `record maps to guest-agent source`() {
        let record = GuestInfoRecord(
            vmId: "vm-1",
            hostname: "guest",
            osName: "Ubuntu",
            osVersion: "24.04",
            osId: "ubuntu",
            kernelVersion: "6.8",
            kernelRelease: "6.8.0",
            machine: "aarch64",
            timezone: "UTC",
            timezoneOffset: 0,
            ipAddresses: #"["192.168.64.10"]"#,
            macAddress: "52:54:00:12:34:56",
            users: nil,
            filesystems: nil,
            updatedAt: "2026-08-19T00:00:00Z",
        )
        let result = GuestAgentInventory.result(from: record)
        #expect(result.available)
        #expect(result.ipSource == "guest-agent")
        #expect(result.ipAddresses == ["192.168.64.10"])
        #expect(result.hostname == "guest")
    }

    @Test func `empty ips stay waiting not invented`() {
        let record = GuestInfoRecord(
            vmId: "vm-1",
            hostname: nil,
            osName: nil,
            osVersion: nil,
            osId: nil,
            kernelVersion: nil,
            kernelRelease: nil,
            machine: nil,
            timezone: nil,
            timezoneOffset: nil,
            ipAddresses: "[]",
            macAddress: nil,
            users: nil,
            filesystems: nil,
            updatedAt: "2026-08-19T00:00:00Z",
        )
        let result = GuestAgentInventory.result(from: record)
        #expect(result.available)
        #expect(result.ipSource == "waiting")
        #expect(result.ipAddresses.isEmpty)
    }

    @Test func `nat fallback is slirp ipv4`() {
        let nat = Network(
            id: "net-1", name: "nat", mode: "nat",
            bridge: nil, macAddress: nil, dnsServer: nil,
            autoCreated: false, isDefault: true,
        )
        let result = GuestAgentInventory.fallbackResult(network: nat)
        #expect(!result.available)
        #expect(result.ipSource == "nat-default")
        #expect(result.ipAddresses == [HealthProbeTarget.slirpGuestIPv4])
    }

    @Test func `bridged fallback waits with mac`() {
        let bridged = Network(
            id: "net-2", name: "br", mode: "bridged",
            bridge: "br0", macAddress: "52:54:00:aa:bb:cc", dnsServer: nil,
            autoCreated: false, isDefault: false,
        )
        let result = GuestAgentInventory.fallbackResult(network: bridged)
        #expect(!result.available)
        #expect(result.ipSource == "waiting")
        #expect(result.macAddress == "52:54:00:aa:bb:cc")
        #expect(result.ipAddresses.isEmpty)
    }
}

@Suite("GuestHealthStore")
final class GuestHealthStoreTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func `last seen and ips come from guest_info`() async throws {
        try await dbPool.write { db in
            try Disk(
                id: "d1",
                name: "boot",
                path: "/tmp/d1.qcow2",
                sizeBytes: 1_000_000,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: "2026-08-19T00:00:00Z",
            ).insert(db)
            try VM(
                id: "vm-a", name: "test", vmType: "linux-arm64", state: "running",
                cpuCount: min(2, max(1, PlatformHost.cpuCount)), memoryMb: 1_024,
                bootDiskId: "d1", networkId: nil,
                cloudInitPath: nil, description: nil, bootOrder: "cd",
                displayResolution: "1280x800", additionalDiskIds: nil, uefi: true,
                tpmEnabled: false, macAddress: nil, sharedPaths: nil,
                portForwards: nil, autoCreated: false, pendingChanges: false,
                createdAt: "2026-08-19T00:00:00Z", updatedAt: "2026-08-19T00:00:00Z",
            ).insert(db)
            try GuestInfoRecord(
                vmId: "vm-a",
                hostname: "a",
                osName: nil,
                osVersion: nil,
                osId: nil,
                kernelVersion: nil,
                kernelRelease: nil,
                machine: nil,
                timezone: nil,
                timezoneOffset: nil,
                ipAddresses: #"["10.1.1.4"]"#,
                macAddress: nil,
                users: nil,
                filesystems: nil,
                updatedAt: "2026-08-19T12:00:00Z",
            ).insert(db)
        }

        let seen = try await GuestHealthStore.lastSeen(ids: ["vm-a", "missing"], db: dbPool)
        #expect(seen["vm-a"] == "2026-08-19T12:00:00Z")
        #expect(seen["missing"] == nil)

        let ips = await GuestHealthStore.ipsByVM(ids: ["vm-a"], db: dbPool)
        #expect(ips["vm-a"] == ["10.1.1.4"])
    }
}
