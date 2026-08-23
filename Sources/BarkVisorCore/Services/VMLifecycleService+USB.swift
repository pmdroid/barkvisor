import Foundation
import GRDB

extension VMLifecycleService {
    public static func attachUSB(
        vmID: String,
        deviceId: String,
        db: DatabasePool,
    ) async throws -> VM {
        try PlatformCapabilities.requireUSBPassthrough()
        let hosts = try USBDeviceService.listDevices()
        let host = try USBPassthroughService.resolveAttachable(deviceId: deviceId, hostDevices: hosts)
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: vmID) }) else {
            throw BarkVisorError.notFound()
        }
        try AgentWorkloadPolicy.assertUSBAllowed(vm.workloadClass)
        var devices = vm.decodedUSBDevices
        if USBPassthroughService.contains(devices, host: host) {
            return vm
        }
        devices.append(USBPassthroughService.passthrough(from: host))
        // Occupancy is re-checked inside updateVM's write (not this read).
        return try await updateVM(
            id: vmID,
            params: UpdateVMParams(usbDevices: devices),
            db: db,
        )
    }

    public static func detachUSB(
        vmID: String,
        deviceId: String,
        db: DatabasePool,
    ) async throws -> VM {
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: vmID) }) else {
            throw BarkVisorError.notFound()
        }
        let hosts = (try? USBDeviceService.listDevices()) ?? []
        let remaining = USBPassthroughService.removing(
            vm.decodedUSBDevices,
            deviceId: deviceId,
            hostDevices: hosts,
        )
        if remaining.count == vm.decodedUSBDevices.count {
            throw BarkVisorError.notFound("USB device \(deviceId) is not attached")
        }
        return try await updateVM(
            id: vmID,
            params: UpdateVMParams(usbDevices: remaining),
            db: db,
        )
    }

    static func persistableUSBDevices(
        _ devices: [USBPassthroughDevice]?,
        hostDevices: [HostUSBDevice]? = nil,
    ) throws -> [USBPassthroughDevice]? {
        guard devices != nil else { return nil }
        let hosts = hostDevices ?? ((try? USBDeviceService.listDevices()) ?? [])
        return try USBPassthroughService.normalizeForPersist(devices, hostDevices: hosts)
    }

    static func assertUSBUnclaimed(
        _ devices: [USBPassthroughDevice]?,
        excludingVMId: String? = nil,
        db: Database,
        hostDevices: [HostUSBDevice] = [],
    ) throws {
        guard let devices, !devices.isEmpty else { return }
        let vms = try VM.fetchAll(db)
        try USBPassthroughService.assertUnclaimed(
            devices: devices,
            vms: vms,
            excludingVMId: excludingVMId,
            hostDevices: hostDevices,
        )
    }
}
