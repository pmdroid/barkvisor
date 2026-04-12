import GRDB
import XCTest
@testable import BarkVisorCore

final class NetworkServiceTests: XCTestCase {
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

    // MARK: - Create

    func testCreateNATNetwork() async throws {
        let network = try await NetworkService.create(
            CreateNetworkParams(name: "test-nat", mode: "nat", bridge: nil, macAddress: nil, dnsServer: "8.8.8.8"),
            db: dbPool,
        )

        XCTAssertEqual(network.name, "test-nat")
        XCTAssertEqual(network.mode, "nat")
        XCTAssertEqual(network.dnsServer, "8.8.8.8")
        XCTAssertFalse(network.autoCreated)
        XCTAssertFalse(network.isDefault)
    }

    func testCreateBridgedNetworkRequiresBridge() async {
        do {
            _ = try await NetworkService.create(
                CreateNetworkParams(name: "test-bridged", mode: "bridged", bridge: nil, macAddress: nil, dnsServer: nil),
                db: dbPool,
            )
            XCTFail("Should require bridge for bridged mode")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 400)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCreateInvalidModeRejected() async {
        do {
            _ = try await NetworkService.create(
                CreateNetworkParams(name: "test", mode: "host-only", bridge: nil, macAddress: nil, dnsServer: nil),
                db: dbPool,
            )
            XCTFail("Should reject invalid mode")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 400)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCreateWithInvalidDNS() async {
        do {
            _ = try await NetworkService.create(
                CreateNetworkParams(name: "test", mode: "nat", bridge: nil, macAddress: nil, dnsServer: "not-an-ip"),
                db: dbPool,
            )
            XCTFail("Should reject invalid DNS")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 400)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCreateWithInvalidMAC() async {
        do {
            _ = try await NetworkService.create(
                CreateNetworkParams(name: "test", mode: "nat", bridge: nil, macAddress: "invalid", dnsServer: nil),
                db: dbPool,
            )
            XCTFail("Should reject invalid MAC")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 400)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Delete

    func testDeleteNetwork() async throws {
        let network = try await NetworkService.create(
            CreateNetworkParams(name: "deleteme", mode: "nat", bridge: nil, macAddress: nil, dnsServer: nil),
            db: dbPool,
        )

        let deleted = try await NetworkService.delete(id: network.id, db: dbPool)
        XCTAssertEqual(deleted?.id, network.id)

        let fetched = try await dbPool.read { db in try Network.fetchOne(db, key: network.id) }
        XCTAssertNil(fetched)
    }

    func testDeleteDefaultNetworkForbidden() async throws {
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

        do {
            _ = try await NetworkService.delete(id: "net-default", db: dbPool)
            XCTFail("Should forbid deleting default network")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 403)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testDeleteNetworkWithAttachedVMs() async throws {
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
                cpuCount: 2, memoryMb: 1_024, bootDiskId: "d1", isoId: nil,
                networkId: network.id, cloudInitPath: nil, vncPort: nil,
                description: nil, bootOrder: "cd", displayResolution: "1280x800",
                additionalDiskIds: nil, uefi: true, tpmEnabled: false,
                macAddress: "52:54:00:12:34:56", sharedPaths: nil, portForwards: nil,
                autoCreated: false, pendingChanges: false,
                createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
            )
            try vm.insert(db)
        }

        do {
            _ = try await NetworkService.delete(id: network.id, db: dbPool)
            XCTFail("Should conflict when VMs are attached")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 409)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Update

    func testUpdateDefaultNetworkForbidden() async throws {
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

        do {
            _ = try await NetworkService.update(
                UpdateNetworkParams(
                    id: "net-default", name: "New Name", mode: nil,
                    bridge: nil, macAddress: nil, dnsServer: nil,
                ),
                db: dbPool,
            )
            XCTFail("Should forbid updating default network")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 403)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testUpdateNonExistent() async {
        do {
            _ = try await NetworkService.update(
                UpdateNetworkParams(id: "fake", name: "New", mode: nil, bridge: nil, macAddress: nil, dnsServer: nil),
                db: dbPool,
            )
            XCTFail("Should throw notFound")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 404)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
