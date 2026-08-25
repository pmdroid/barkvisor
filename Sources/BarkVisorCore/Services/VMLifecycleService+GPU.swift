import Foundation
import GRDB

extension VMLifecycleService {
    public static func attachGPU(
        vmID: String,
        deviceId: String,
        db: DatabasePool,
        hostDevices: [HostGPUDevice]? = nil,
    ) async throws -> VM {
        try PlatformCapabilities.requireVFIOPassthrough()
        let hosts = try listedGPUs(hostDevices: hostDevices)
        let host = try GPUPassthroughService.resolveAttachable(deviceId: deviceId, hostDevices: hosts)
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: vmID) }) else {
            throw BarkVisorError.notFound()
        }
        var devices = vm.decodedGPUDevices
        if !GPUPassthroughService.contains(devices, host: host) {
            devices.append(GPUPassthroughService.passthrough(from: host))
        }
        return try await updateVM(
            id: vmID,
            params: UpdateVMParams(gpuDevices: devices),
            db: db,
            hostGPUDevices: hosts,
        )
    }

    public static func detachGPU(
        vmID: String,
        deviceId: String,
        db: DatabasePool,
    ) async throws -> VM {
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: vmID) }) else {
            throw BarkVisorError.notFound()
        }
        try GPUPassthroughService.assertCanDetach(state: vm.state)
        let remaining = GPUPassthroughService.removing(vm.decodedGPUDevices, deviceId: deviceId)
        let removed = vm.decodedGPUDevices.filter { device in
            !remaining.contains { $0.pciAddress == device.pciAddress }
        }
        let updated = try await updateVM(
            id: vmID,
            params: UpdateVMParams(gpuDevices: remaining),
            db: db,
        )
        GPUPassthroughService.releaseVFIO(removed)
        return updated
    }

    static func persistableGPUDevices(
        _ devices: [GPUPassthroughDevice]?,
        hostDevices: [HostGPUDevice]? = nil,
    ) throws -> [GPUPassthroughDevice]? {
        guard devices != nil else { return nil }
        if devices?.isEmpty == true { return [] }
        try PlatformCapabilities.requireVFIOPassthrough()
        let hosts = try listedGPUs(hostDevices: hostDevices)
        return try GPUPassthroughService.normalizeForPersist(devices, hostDevices: hosts)
    }

    static func assertGPUUnclaimed(
        _ devices: [GPUPassthroughDevice]?,
        excludingVMId: String? = nil,
        db: Database,
        hostDevices: [HostGPUDevice] = [],
    ) throws {
        guard let devices, !devices.isEmpty else { return }
        let vms = try VM.fetchAll(db)
        try GPUPassthroughService.assertUnclaimed(
            devices: devices,
            vms: vms,
            excludingVMId: excludingVMId,
            hostDevices: hostDevices,
        )
    }

    static func syncCodingAgentCloudInitForGPU(vm: VM) throws {
        let stored = CloudInitService.storedUserData(vmID: vm.id)
        guard CodingAgentImage.isManagedUserData(stored) else { return }
        let gpuAttached = GPUPassthroughService.hasDisplayGPU(vm.decodedGPUDevices)
        let userData = CodingAgentImage.userDataForGPU(
            gpuAttached: gpuAttached, existingUserData: stored,
        )
        try CloudInitService.validateUserData(userData)
        let keys = CloudInitService.sshAuthorizedKeys(from: stored)
        _ = try CloudInitService.generateISO(
            vmID: vm.id,
            vmName: vm.name,
            sshKeys: keys,
            userData: userData,
            instanceID: CodingAgentImage.cloudInitInstanceID(vmID: vm.id, gpuAttached: gpuAttached),
        )
    }

    static func releaseGPUDevices(_ devices: [GPUPassthroughDevice]?) {
        GPUPassthroughService.releaseVFIO(devices ?? [])
    }

    private static func listedGPUs(
        hostDevices: [HostGPUDevice]?,
    ) throws -> [HostGPUDevice] {
        if let hostDevices { return hostDevices }
        return GPUDeviceService.listPCIDevices()
    }
}
