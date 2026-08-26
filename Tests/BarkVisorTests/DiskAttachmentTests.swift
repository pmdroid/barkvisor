import Foundation
import Testing
@testable import BarkVisorCore

final class DiskAttachmentTests {
    private func makeVM(
        id: String,
        name: String,
        bootDiskId: String,
        additionalDiskIds: [String]? = nil,
    ) -> VM {
        var vm = VM(
            id: id,
            name: name,
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: 2,
            memoryMb: 1_024,
            bootDiskId: bootDiskId,
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
        vm.setAdditionalDiskIds(additionalDiskIds)
        return vm
    }

    private func makeDisk(id: String, vmId: String? = nil) -> Disk {
        Disk(
            id: id,
            name: "disk-\(id)",
            path: "/data/disks/\(id).qcow2",
            sizeBytes: 1_073_741_824,
            format: "qcow2",
            vmId: vmId,
            autoCreated: false,
            status: "ready",
            createdAt: "2026-01-01T00:00:00Z",
        )
    }

    @Test func `boot disk and additional disks map to their vm`() {
        let vm = makeVM(id: "vm-1", name: "web", bootDiskId: "d-boot", additionalDiskIds: ["d-data", "d-raw"])
        let map = DiskService.attachmentsByDiskId(
            vms: [vm],
            disks: [makeDisk(id: "d-boot"), makeDisk(id: "d-data"), makeDisk(id: "d-raw")],
        )
        #expect(map["d-boot"] == [DiskAttachment(vmId: "vm-1", vmName: "web")])
        #expect(map["d-data"] == [DiskAttachment(vmId: "vm-1", vmName: "web")])
        #expect(map["d-raw"] == [DiskAttachment(vmId: "vm-1", vmName: "web")])
    }

    @Test func `unattached disk has no attachments`() {
        let map = DiskService.attachmentsByDiskId(vms: [], disks: [makeDisk(id: "d-free")])
        #expect(map["d-free"] == nil)
    }

    @Test func `disk vmId fallback applies when vm configs do not reference the disk`() {
        let vm = makeVM(id: "vm-1", name: "web", bootDiskId: "d-boot")
        let map = DiskService.attachmentsByDiskId(
            vms: [vm],
            disks: [makeDisk(id: "d-orphan", vmId: "vm-1")],
        )
        #expect(map["d-orphan"] == [DiskAttachment(vmId: "vm-1", vmName: "web")])
    }

    @Test func `vmId fallback does not duplicate a config-based attachment`() {
        let vm = makeVM(id: "vm-1", name: "web", bootDiskId: "d-boot")
        let map = DiskService.attachmentsByDiskId(
            vms: [vm],
            disks: [makeDisk(id: "d-boot", vmId: "vm-1")],
        )
        #expect(map["d-boot"] == [DiskAttachment(vmId: "vm-1", vmName: "web")])
    }

    @Test func `vmId fallback keeps id as name when vm row is gone`() {
        let map = DiskService.attachmentsByDiskId(
            vms: [],
            disks: [makeDisk(id: "d-stale", vmId: "vm-gone")],
        )
        #expect(map["d-stale"] == [DiskAttachment(vmId: "vm-gone", vmName: "vm-gone")])
    }

    @Test func `two vms sharing a disk both appear`() {
        let a = makeVM(id: "vm-1", name: "web", bootDiskId: "d-a", additionalDiskIds: ["d-shared"])
        let b = makeVM(id: "vm-2", name: "db", bootDiskId: "d-b", additionalDiskIds: ["d-shared"])
        let map = DiskService.attachmentsByDiskId(vms: [a, b], disks: [makeDisk(id: "d-shared")])
        #expect(map["d-shared"] == [
            DiskAttachment(vmId: "vm-1", vmName: "web"),
            DiskAttachment(vmId: "vm-2", vmName: "db"),
        ])
    }
}
