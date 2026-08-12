import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class NetworkServiceTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Create

    @Test func `create NAT network`() async throws {
        let network = try await NetworkService.create(
            CreateNetworkParams(name: "test-nat", mode: "nat", bridge: nil, macAddress: nil, dnsServer: "8.8.8.8"),
            db: dbPool,
        )

        #expect(network.name == "test-nat")
        #expect(network.mode == "nat")
        #expect(network.dnsServer == "8.8.8.8")
        #expect(!network.autoCreated)
        #expect(!network.isDefault)
    }

    @Test func `create bridged network requires bridge`() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(name: "test-bridged", mode: "bridged", bridge: nil, macAddress: nil, dnsServer: nil),
                db: self.dbPool,
            )
        }
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        if advertised {
            #expect(error?.httpStatus == 400)
        } else {
            #expect(error?.httpStatus == 422)
            #expect(error?.code == "bridged_networking")
        }
    }

    @Test func `create bridged network returns 422 when product flag is off`() async {
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        guard !advertised else { return }
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(name: "test-bridged", mode: "bridged", bridge: "br0", macAddress: nil, dnsServer: nil),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 422)
        #expect(error?.code == "bridged_networking")
    }

    @Test func `create bridged missing interface is 422 when advertised`() async {
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        guard advertised else { return }
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(
                    name: "ghost-br", mode: "bridged", bridge: "bv-missing-if",
                    macAddress: nil, dnsServer: nil,
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 422)
        #expect(error?.code == "interface_missing")
    }

    @Test func `create bridged invalid name is invalid_bridge when advertised`() async {
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        guard advertised else { return }
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(
                    name: "bad-br", mode: "bridged", bridge: "bad name!",
                    macAddress: nil, dnsServer: nil,
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 400)
        #expect(error?.code == "invalid_bridge")
    }

    @Test func `create VM port forwards on isolated rejected`() async throws {
        let isolated = try await NetworkService.create(
            CreateNetworkParams(
                name: "private", mode: "isolated", bridge: nil, macAddress: nil, dnsServer: nil,
            ),
            db: dbPool,
        )
        let hostLinux = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        let error = await #expect(throws: BarkVisorError.self) {
            try await VMLifecycleService.validateCreateVMInputs(
                params: CreateVMParams(
                    name: "pf-iso",
                    vmType: hostLinux,
                    cpuCount: min(2, max(1, PlatformHost.cpuCount)),
                    memoryMB: 512,
                    isoId: "iso-1",
                    networkId: isolated.id,
                    portForwards: [
                        PortForwardRule(protocol: "tcp", hostPort: 8_080, guestPort: 80),
                    ],
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 400)
        #expect(error?.code == "invalid_port_forward")
    }

    @Test func `create VM port forwards on implicit NAT allowed`() async throws {
        let hostLinux = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        try await VMLifecycleService.validateCreateVMInputs(
            params: CreateVMParams(
                name: "pf-nat",
                vmType: hostLinux,
                cpuCount: min(2, max(1, PlatformHost.cpuCount)),
                memoryMB: 512,
                isoId: "iso-1",
                networkId: nil,
                portForwards: [
                    PortForwardRule(protocol: "tcp", hostPort: 8_080, guestPort: 80),
                ],
            ),
            db: dbPool,
        )
    }

    @Test func `create isolated network`() async throws {
        let network = try await NetworkService.create(
            CreateNetworkParams(
                name: "private", mode: "isolated", bridge: nil, macAddress: nil, dnsServer: nil,
            ),
            db: dbPool,
        )
        #expect(network.mode == "isolated")
        #expect(network.bridge == nil)
    }

    @Test func `create isolated rejects bridge field`() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(
                    name: "private", mode: "isolated", bridge: "br0", macAddress: nil, dnsServer: nil,
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 400)
        #expect(error?.errorDescription?.contains("bridge") == true)
    }

    @Test func `create invalid mode rejected`() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(name: "test", mode: "host-only", bridge: nil, macAddress: nil, dnsServer: nil),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 400)
    }

    @Test func `create with invalid DNS`() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(name: "test", mode: "nat", bridge: nil, macAddress: nil, dnsServer: "not-an-ip"),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 400)
    }

    @Test func `create with invalid MAC`() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(name: "test", mode: "nat", bridge: nil, macAddress: "invalid", dnsServer: nil),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 400)
    }

    // MARK: - Delete

    @Test func `delete network`() async throws {
        let network = try await NetworkService.create(
            CreateNetworkParams(name: "deleteme", mode: "nat", bridge: nil, macAddress: nil, dnsServer: nil),
            db: dbPool,
        )

        let deleted = try await NetworkService.delete(id: network.id, db: dbPool)
        #expect(deleted?.id == network.id)

        let fetched = try await dbPool.read { db in try Network.fetchOne(db, key: network.id) }
        #expect(fetched == nil)
    }

    @Test func `delete default network forbidden`() async throws {
        // Insert a default network directly
        try await dbPool.write { db in
            let net = Network(
                id: "net-default",
                name: "Default NAT",
                mode: "nat",
                bridge: nil,
                macAddress: nil,
                dnsServer: nil,
                autoCreated: true,
                isDefault: true,
            )
            try net.insert(db)
        }

        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.delete(id: "net-default", db: self.dbPool)
        }
        #expect(error?.httpStatus == 403)
    }

    @Test func `delete network with attached V ms`() async throws {
        let network = try await NetworkService.create(
            CreateNetworkParams(name: "in-use", mode: "nat", bridge: nil, macAddress: nil, dnsServer: nil),
            db: dbPool,
        )

        // Create a disk and VM attached to this network
        try await dbPool.write { db in
            let disk = Disk(
                id: "d1",
                name: "boot",
                path: "/tmp/d1.qcow2",
                sizeBytes: 1_000_000,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: "2025-01-01T00:00:00Z",
            )
            try disk.insert(db)

            let vm = VM(
                id: "vm1", name: "test", vmType: "linux-arm64", state: "stopped",
                cpuCount: 2, memoryMb: 1_024, bootDiskId: "d1",
                networkId: network.id, cloudInitPath: nil,
                description: nil, bootOrder: "cd", displayResolution: "1280x800",
                additionalDiskIds: nil, uefi: true, tpmEnabled: false,
                macAddress: "52:54:00:12:34:56", sharedPaths: nil, portForwards: nil,
                autoCreated: false, pendingChanges: false,
                createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
            )
            try vm.insert(db)
        }

        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.delete(id: network.id, db: self.dbPool)
        }
        #expect(error?.httpStatus == 409)
    }

    // MARK: - Update

    @Test func `update default network forbidden`() async throws {
        try await dbPool.write { db in
            let net = Network(
                id: "net-default",
                name: "Default",
                mode: "nat",
                bridge: nil,
                macAddress: nil,
                dnsServer: nil,
                autoCreated: true,
                isDefault: true,
            )
            try net.insert(db)
        }

        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.update(
                UpdateNetworkParams(
                    id: "net-default", name: "New Name", mode: nil,
                    bridge: nil, macAddress: nil, dnsServer: nil,
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 403)
    }

    @Test func `update non existent`() async {
        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.update(
                UpdateNetworkParams(id: "fake", name: "New", mode: nil, bridge: nil, macAddress: nil, dnsServer: nil),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 404)
    }
}
