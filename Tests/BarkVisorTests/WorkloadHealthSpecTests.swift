import Foundation
import Testing
@testable import BarkVisorCore

@Suite("WorkloadHealthSpec")
struct WorkloadHealthSpecTests {
    private var fixtureCPUCount: Int {
        min(2, max(1, PlatformHost.cpuCount))
    }

    @Test func `health spec round trips through columns`() throws {
        var vm = VM(
            id: "vm-1",
            name: "media",
            vmType: "linux-arm64",
            state: "running",
            cpuCount: fixtureCPUCount,
            memoryMb: 8_192,
            bootDiskId: "disk-boot",
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
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-06-01T00:00:00Z",
        )
        let health = WorkloadHealthSpec(
            intervalSec: 30,
            timeoutSec: 5,
            http: WorkloadHealthHTTPCheck(path: "/health", port: 8_080),
            tcp: WorkloadHealthTCPCheck(port: 22),
        )
        var spec = WorkloadSpecProjector.fromVM(vm)
        spec.spec.health = health
        try WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.decodedHealth?.http?.port == 8_080)
        #expect(vm.decodedHealth?.tcp?.port == 22)
        let again = WorkloadSpecProjector.fromVM(vm)
        #expect(again.spec.health == health)

        spec.spec.health = WorkloadHealthSpec()
        try WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.decodedHealth == nil)

        spec.spec.health = health
        try WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.decodedHealth?.http?.port == 8_080)
        spec.spec.health = nil
        try WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.decodedHealth == nil)
        #expect(vm.healthJson == nil)
    }

    @Test func `ssa merge keeps omitted health and clears explicit null`() throws {
        var vm = VM(
            id: "vm-1",
            name: "media",
            vmType: "linux-arm64",
            state: "running",
            cpuCount: fixtureCPUCount,
            memoryMb: 8_192,
            bootDiskId: "disk-boot",
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
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-06-01T00:00:00Z",
        )
        let health = WorkloadHealthSpec(
            http: WorkloadHealthHTTPCheck(path: "/health", port: 8_080),
        )
        var spec = WorkloadSpecProjector.fromVM(vm)
        spec.spec.health = health
        try WorkloadSpecProjector.apply(spec, to: &vm)

        let omitted = try WorkloadSpecDocument.merge(
            base: WorkloadSpecProjector.fromVM(vm),
            overlay: ["spec": ["resources": ["memoryMb": 4_096]]],
        )
        #expect(omitted.spec.health == health)
        try WorkloadSpecProjector.apply(omitted, to: &vm)
        #expect(vm.decodedHealth == health)
        #expect(vm.memoryMb == 4_096)

        let cleared = try WorkloadSpecDocument.merge(
            base: WorkloadSpecProjector.fromVM(vm),
            overlay: ["spec": ["health": NSNull()]],
        )
        #expect(cleared.spec.health == nil)
        try WorkloadSpecProjector.apply(cleared, to: &vm)
        #expect(vm.decodedHealth == nil)
        #expect(vm.healthJson == nil)
    }

    @Test func `exec health is rejected on virtual machines`() {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "n"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 1, memoryMb: 512),
                health: WorkloadHealthSpec(exec: WorkloadHealthExecCheck(command: ["true"])),
            ),
        )
        #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.validate(spec)
        }
    }
}
