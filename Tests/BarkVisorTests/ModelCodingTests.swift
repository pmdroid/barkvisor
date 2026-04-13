import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct ModelCodingTests {
    // MARK: - VM Codable

    @Test func `vm codable`() throws {
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

        #expect(decoded.id == vm.id)
        #expect(decoded.name == vm.name)
        #expect(decoded.vmType == vm.vmType)
        #expect(decoded.state == vm.state)
        #expect(decoded.cpuCount == vm.cpuCount)
        #expect(decoded.memoryMb == vm.memoryMb)
        #expect(decoded.bootDiskId == vm.bootDiskId)
        #expect(decoded.networkId == vm.networkId)
        #expect(decoded.description == vm.description)
        #expect(decoded.bootOrder == vm.bootOrder)
        #expect(decoded.displayResolution == vm.displayResolution)
        #expect(decoded.uefi == vm.uefi)
        #expect(decoded.tpmEnabled == vm.tpmEnabled)
        #expect(decoded.macAddress == vm.macAddress)
        #expect(decoded.autoCreated == vm.autoCreated)
        #expect(decoded.pendingChanges == vm.pendingChanges)
    }

    // MARK: - Disk Codable

    @Test func `disk codable`() throws {
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

        #expect(decoded.id == disk.id)
        #expect(decoded.name == disk.name)
        #expect(decoded.path == disk.path)
        #expect(decoded.sizeBytes == disk.sizeBytes)
        #expect(decoded.format == disk.format)
        #expect(decoded.vmId == disk.vmId)
    }

    // MARK: - PortForwardRule Codable

    @Test func `port forward rule codable`() throws {
        let rule = PortForwardRule(protocol: "tcp", hostPort: 2_222, guestPort: 22)

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(PortForwardRule.self, from: data)

        #expect(decoded.protocol == "tcp")
        #expect(decoded.hostPort == 2_222)
        #expect(decoded.guestPort == 22)
    }

    // MARK: - Network Codable

    @Test func `network codable`() throws {
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

        #expect(decoded.id == network.id)
        #expect(decoded.name == network.name)
        #expect(decoded.mode == network.mode)
        #expect(decoded.macAddress == network.macAddress)
        #expect(decoded.dnsServer == network.dnsServer)
        #expect(decoded.isDefault == network.isDefault)
    }

    // MARK: - BarkVisorError

    @Test func `bark visor error descriptions`() throws {
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
            #expect(error.errorDescription != nil, "errorDescription should not be nil for \(error)")
            let desc = try #require(error.errorDescription)
            #expect(!desc.isEmpty, "errorDescription should not be empty for \(error)")
        }
    }
}
