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
        let vms = try await db.read { db in try VM.fetchAll(db) }
        if let claim = USBPassthroughService.claimedBy(host: host, vms: vms, excludingVMId: vmID) {
            throw BarkVisorError.conflict("USB device is attached to \(claim.name)")
        }
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: vmID) }) else {
            throw BarkVisorError.notFound()
        }
        var devices = vm.decodedUSBDevices
        if USBPassthroughService.contains(devices, host: host) {
            return vm
        }
        devices.append(USBPassthroughService.passthrough(from: host))
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
        let remaining = USBPassthroughService.removing(vm.decodedUSBDevices, deviceId: deviceId)
        return try await updateVM(
            id: vmID,
            params: UpdateVMParams(usbDevices: remaining),
            db: db,
        )
    }

    static func persistableUSBDevices(
        _ devices: [USBPassthroughDevice]?,
    ) throws -> [USBPassthroughDevice]? {
        guard devices != nil else { return nil }
        let hosts = (try? USBDeviceService.listDevices()) ?? []
        return try USBPassthroughService.normalizeForPersist(devices, hostDevices: hosts)
    }
}
