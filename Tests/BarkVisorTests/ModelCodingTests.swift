import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

final class ModelCodingTests: XCTestCase {
    // MARK: - VM Codable

    func testVMCodable() throws {
        let vm = VM(
            id: "test-id",
            name: "test-vm",
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: 4,
            memoryMb: 2_048,
            bootDiskId: "disk-1",
            isoId: nil,
            networkId: "net-1",
            cloudInitPath: nil,
            vncPort: nil,
            description: "A test VM",
            bootOrder: "cd",
            displayResolution: "1280x800",
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: "52:54:00:12:34:56",
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let data = try JSONEncoder().encode(vm)
        let decoded = try JSONDecoder().decode(VM.self, from: data)

        XCTAssertEqual(decoded.id, vm.id)
        XCTAssertEqual(decoded.name, vm.name)
        XCTAssertEqual(decoded.vmType, vm.vmType)
        XCTAssertEqual(decoded.state, vm.state)
        XCTAssertEqual(decoded.cpuCount, vm.cpuCount)
        XCTAssertEqual(decoded.memoryMb, vm.memoryMb)
        XCTAssertEqual(decoded.bootDiskId, vm.bootDiskId)
        XCTAssertEqual(decoded.networkId, vm.networkId)
        XCTAssertEqual(decoded.description, vm.description)
        XCTAssertEqual(decoded.bootOrder, vm.bootOrder)
        XCTAssertEqual(decoded.displayResolution, vm.displayResolution)
        XCTAssertEqual(decoded.uefi, vm.uefi)
        XCTAssertEqual(decoded.tpmEnabled, vm.tpmEnabled)
        XCTAssertEqual(decoded.macAddress, vm.macAddress)
        XCTAssertEqual(decoded.autoCreated, vm.autoCreated)
        XCTAssertEqual(decoded.pendingChanges, vm.pendingChanges)
    }

    // MARK: - Disk Codable

    func testDiskCodable() throws {
        let disk = Disk(
            id: "disk-1",
            name: "boot",
            path: "/data/disks/boot.qcow2",
            sizeBytes: 21_474_836_480,
            format: "qcow2",
            vmId: "vm-1",
            autoCreated: false,
            status: "ready",
            createdAt: "2025-01-01T00:00:00Z",
        )

        let data = try JSONEncoder().encode(disk)
        let decoded = try JSONDecoder().decode(Disk.self, from: data)

        XCTAssertEqual(decoded.id, disk.id)
        XCTAssertEqual(decoded.name, disk.name)
        XCTAssertEqual(decoded.path, disk.path)
        XCTAssertEqual(decoded.sizeBytes, disk.sizeBytes)
        XCTAssertEqual(decoded.format, disk.format)
        XCTAssertEqual(decoded.vmId, disk.vmId)
    }

    // MARK: - PortForwardRule Codable

    func testPortForwardRuleCodable() throws {
        let rule = PortForwardRule(protocol: "tcp", hostPort: 2_222, guestPort: 22)

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(PortForwardRule.self, from: data)

        XCTAssertEqual(decoded.protocol, "tcp")
        XCTAssertEqual(decoded.hostPort, 2_222)
        XCTAssertEqual(decoded.guestPort, 22)
    }

    // MARK: - Network Codable

    func testNetworkCodable() throws {
        let network = Network(
            id: "net-1",
            name: "default",
            mode: "nat",
            bridge: nil,
            macAddress: "52:54:00:AA:BB:CC",
            dnsServer: "8.8.8.8",
            autoCreated: true,
            isDefault: true,
        )

        let data = try JSONEncoder().encode(network)
        let decoded = try JSONDecoder().decode(Network.self, from: data)

        XCTAssertEqual(decoded.id, network.id)
        XCTAssertEqual(decoded.name, network.name)
        XCTAssertEqual(decoded.mode, network.mode)
        XCTAssertEqual(decoded.macAddress, network.macAddress)
        XCTAssertEqual(decoded.dnsServer, network.dnsServer)
        XCTAssertEqual(decoded.isDefault, network.isDefault)
    }

    // MARK: - BarkVisorError

    func testBarkVisorErrorDescriptions() throws {
        let errors: [BarkVisorError] = [
            .qemuNotFound("not found"),
            .firmwareNotFound("missing"),
            .unknownVMType("bad-type"),
            .diskCreateFailed("failed"),
            .cloudInitFailed("failed"),
            .monitorError("error"),
            .vmNotRunning("vm-1"),
            .vmAlreadyRunning("vm-1"),
            .ptyParseFailed,
            .processSpawnFailed("failed"),
            .repositoryNotFound("repo-1"),
            .repositorySyncFailed("failed"),
            .invalidPortForward("bad"),
            .decompressFailed("failed"),
            .downloadFailed("failed"),
            .invalidArgument("bad"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "errorDescription should not be nil for \(error)")
            XCTAssertFalse(
                try XCTUnwrap(error.errorDescription?.isEmpty),
                "errorDescription should not be empty for \(error)",
            )
        }
    }
}
