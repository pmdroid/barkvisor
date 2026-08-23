import Foundation
import GRDB

extension VMLifecycleService {
    public static func attachGPU(
        vmID: String,
        deviceId: String,
        db: DatabasePool,
        hostDevices: [HostGPUDevice]? = nil,
        hostOllamaReachable: Bool? = nil,
    ) async throws -> VM {
        try PlatformCapabilities.requireGPUPassthrough()
        let hosts = try listedGPUs(hostDevices: hostDevices, hostOllamaReachable: hostOllamaReachable)
        let host = try GPUPassthroughService.resolveAttachable(deviceId: deviceId, hostDevices: hosts)
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: vmID) }) else {
            throw BarkVisorError.notFound()
        }
        var devices = vm.decodedGPUDevices
        if GPUPassthroughService.contains(devices, host: host) {
            return vm
        }
        devices.append(GPUPassthroughService.passthrough(from: host))
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
        let remaining = GPUPassthroughService.removing(vm.decodedGPUDevices, deviceId: deviceId)
        return try await updateVM(
            id: vmID,
            params: UpdateVMParams(gpuDevices: remaining),
            db: db,
        )
    }

    static func persistableGPUDevices(
        _ devices: [GPUPassthroughDevice]?,
        hostDevices: [HostGPUDevice]? = nil,
        hostOllamaReachable: Bool? = nil,
    ) throws -> [GPUPassthroughDevice]? {
        guard devices != nil else { return nil }
        if devices?.isEmpty == true { return [] }
        try PlatformCapabilities.requireGPUPassthrough()
        let hosts = try listedGPUs(hostDevices: hostDevices, hostOllamaReachable: hostOllamaReachable)
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

    private static func listedGPUs(
        hostDevices: [HostGPUDevice]?,
        hostOllamaReachable: Bool?,
    ) throws -> [HostGPUDevice] {
        if let hostDevices { return hostDevices }
        return GPUDeviceService.listDevices(
            hostOllamaReachable: hostOllamaReachable ?? GPUPassthroughService.liveHostOllamaReachable(),
        )
    }
}
