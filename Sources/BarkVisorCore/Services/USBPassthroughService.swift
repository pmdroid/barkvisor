import Foundation

/// Resolve, claim, and persist USB passthrough by stable id (PAS-84).
public enum USBPassthroughService {
    public static func passthrough(from host: HostUSBDevice) -> USBPassthroughDevice {
        persistUniquePair(
            USBPassthroughDevice(
                vendorId: host.vendorId,
                productId: host.productId,
                label: host.name,
                serialNumber: host.serialNumber,
                deviceId: host.id,
            ),
            host: host,
        )
    }

    public static func workload(from device: USBPassthroughDevice) -> WorkloadUSBDevice {
        WorkloadUSBDevice(
            vendorId: device.vendorId,
            productId: device.productId,
            label: device.label,
            serialNumber: device.serialNumber,
            deviceId: device.deviceId,
        )
    }

    public static func passthrough(from spec: WorkloadUSBDevice) -> USBPassthroughDevice {
        USBPassthroughDevice(
            vendorId: spec.vendorId,
            productId: spec.productId,
            label: spec.label,
            serialNumber: spec.serialNumber,
            deviceId: spec.deviceId,
        )
    }

    public static func matches(_ device: USBPassthroughDevice, host: HostUSBDevice) -> Bool {
        if let deviceId = device.deviceId, !USBDeviceIdentity.isBusAddressId(deviceId),
           deviceId == host.id {
            return true
        }
        if let deviceId = device.deviceId, !USBDeviceIdentity.isBusAddressId(deviceId),
           let parsed = USBDeviceIdentity.parse(deviceId) {
            if matches(parsed, host: host) { return true }
        }
        if let serial = USBDeviceIdentity.normalizedSerial(device.serialNumber),
           let hostSerial = host.serialNumber,
           serial == hostSerial,
           USBDeviceIdentity.normalizeHexId(device.vendorId) == host.vendorId,
           USBDeviceIdentity.normalizeHexId(device.productId) == host.productId {
            return true
        }
        return false
    }

    public static func matches(_ ref: USBDeviceIdentity.Ref, host: HostUSBDevice) -> Bool {
        if !USBDeviceIdentity.isBusAddressId(ref.id), ref.id == host.id { return true }
        if let serial = ref.serial, let hostSerial = host.serialNumber, serial == hostSerial {
            if ref.vendorId.isEmpty || ref.vendorId == host.vendorId,
               ref.productId.isEmpty || ref.productId == host.productId {
                return true
            }
        }
        return false
    }

    public static func busAddressIdentityError(_ id: String) -> BarkVisorError {
        .conflict(
            "USB device id \(id) is a bus address, which is not stable across replug. "
                + "Re-attach using serial or a unique vendor/product pair.",
        )
    }

    public static func resolve(
        deviceId: String,
        hostDevices: [HostUSBDevice],
    ) throws -> HostUSBDevice {
        let trimmed = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = USBDeviceIdentity.parse(trimmed) else {
            throw BarkVisorError.badRequest("Invalid USB device id")
        }
        if USBDeviceIdentity.isBusAddressId(trimmed) || (parsed.serial == nil && parsed.bus != nil) {
            return try resolveLiveBusAddress(parsed, hostDevices: hostDevices)
        }
        let matched = hostDevices.filter { matches(parsed, host: $0) }
        if matched.count == 1, let found = matched.first {
            return found
        }
        if matched.count > 1 {
            throw BarkVisorError.conflict(
                "USB device id \(trimmed) matches multiple host devices; unplug extras or attach by serial",
            )
        }
        if parsed.serial == nil, parsed.bus == nil, !parsed.vendorId.isEmpty {
            let samePair = hostDevices.filter {
                $0.vendorId == parsed.vendorId && $0.productId == parsed.productId && $0.attachable
            }
            if samePair.count == 1, let found = samePair.first { return found }
            if samePair.count > 1 {
                throw BarkVisorError.conflict(
                    "Multiple USB devices share \(parsed.vendorId):\(parsed.productId); attach by serial or device id",
                )
            }
        }
        throw BarkVisorError.notFound("USB device \(trimmed) is not connected")
    }

    /// `bus:BBB.AAA` locates a currently plugged device. It is not persisted.
    private static func resolveLiveBusAddress(
        _ parsed: USBDeviceIdentity.Ref,
        hostDevices: [HostUSBDevice],
    ) throws -> HostUSBDevice {
        let live = hostDevices.filter { $0.bus == parsed.bus && $0.address == parsed.address }
        if live.count > 1 {
            throw BarkVisorError.conflict(
                "USB device id \(parsed.id) matches multiple host devices; unplug extras or attach by serial",
            )
        }
        guard let found = live.first else {
            throw BarkVisorError.notFound("USB device \(parsed.id) is not connected")
        }
        let samePair = hostDevices.filter {
            $0.vendorId == found.vendorId && $0.productId == found.productId && $0.attachable
        }
        if found.serialNumber == nil, samePair.count > 1 {
            throw BarkVisorError.conflict(
                "Multiple USB devices share \(found.vendorId):\(found.productId); attach by serial",
            )
        }
        return found
    }

    public static func resolveAttachable(
        deviceId: String,
        hostDevices: [HostUSBDevice],
    ) throws -> HostUSBDevice {
        let host = try resolve(deviceId: deviceId, hostDevices: hostDevices)
        guard host.attachable else {
            throw BarkVisorError.badRequest(
                host.excludedReason ?? USBDeviceIdentity.massStorageExclusionReason,
            )
        }
        return host
    }

    public static func claimedBy(
        host: HostUSBDevice,
        vms: [VM],
        excludingVMId: String? = nil,
    ) -> (id: String, name: String)? {
        for vm in vms {
            if vm.id == excludingVMId { continue }
            if vm.decodedUSBDevices.contains(where: { matches($0, host: host) }) {
                return (id: vm.id, name: vm.name)
            }
            // Legacy vid:pid-only attachments claim a unique host of that pair.
            if vm.decodedUSBDevices.contains(where: { legacyVIDPIDMatch($0, host: host) }) {
                return (id: vm.id, name: vm.name)
            }
        }
        return nil
    }

    /// Reject devices already attached to another VM. Used on every persist
    /// path (create / update / spec / attach) so occupancy is not attach-only.
    public static func assertUnclaimed(
        devices: [USBPassthroughDevice],
        vms: [VM],
        excludingVMId: String? = nil,
        hostDevices: [HostUSBDevice] = [],
    ) throws {
        for device in devices {
            let host = resolvedOrSyntheticHost(device, hostDevices: hostDevices)
            if let claim = claimedBy(host: host, vms: vms, excludingVMId: excludingVMId) {
                throw BarkVisorError.conflict("USB device is attached to \(claim.name)")
            }
        }
    }

    public static func contains(_ devices: [USBPassthroughDevice], host: HostUSBDevice) -> Bool {
        devices.contains { matches($0, host: host) || legacyVIDPIDEquals($0, host: host) }
    }

    public static func removing(
        _ devices: [USBPassthroughDevice],
        deviceId: String,
    ) -> [USBPassthroughDevice] {
        guard let parsed = USBDeviceIdentity.parse(deviceId) else {
            return devices.filter { $0.deviceId != deviceId }
        }
        return devices.filter { device in
            if let existing = device.deviceId, existing == parsed.id { return false }
            if matches(device, host: syntheticHost(from: parsed, fallback: device)) {
                return false
            }
            if parsed.serial == nil, parsed.bus == nil,
               USBDeviceIdentity.normalizeHexId(device.vendorId) == parsed.vendorId,
               USBDeviceIdentity.normalizeHexId(device.productId) == parsed.productId,
               device.serialNumber == nil {
                return false
            }
            return true
        }
    }

    public static func normalizeForPersist(
        _ devices: [USBPassthroughDevice]?,
        hostDevices: [HostUSBDevice],
    ) throws -> [USBPassthroughDevice]? {
        guard let devices else { return nil }
        if devices.isEmpty { return [] }
        var result: [USBPassthroughDevice] = []
        for device in devices {
            let normalized = try normalizeOne(device, hostDevices: hostDevices)
            if result.contains(where: { $0.deviceId == normalized.deviceId }) {
                throw BarkVisorError.badRequest("Duplicate USB device \(normalized.deviceId ?? "")")
            }
            result.append(normalized)
        }
        return result
    }

    public static func normalizeOne(
        _ device: USBPassthroughDevice,
        hostDevices: [HostUSBDevice],
    ) throws -> USBPassthroughDevice {
        if let deviceId = device.deviceId, USBDeviceIdentity.isBusAddressId(deviceId) {
            throw busAddressIdentityError(deviceId)
        }

        if let deviceId = device.deviceId, let parsed = USBDeviceIdentity.parse(deviceId),
           parsed.serial != nil {
            if let host = try? resolve(deviceId: deviceId, hostDevices: hostDevices) {
                guard host.attachable else {
                    throw BarkVisorError.badRequest(
                        host.excludedReason ?? USBDeviceIdentity.massStorageExclusionReason,
                    )
                }
                return USBPassthroughDevice(
                    vendorId: host.vendorId,
                    productId: host.productId,
                    label: device.label ?? host.name,
                    serialNumber: host.serialNumber,
                    deviceId: host.id,
                )
            }
            return USBPassthroughDevice(
                vendorId: device.vendorId,
                productId: device.productId,
                label: device.label,
                serialNumber: device.serialNumber,
                deviceId: deviceId,
            )
        }

        if let serial = USBDeviceIdentity.normalizedSerial(device.serialNumber) {
            let ref = USBDeviceIdentity.make(
                vendorId: device.vendorId, productId: device.productId, serial: serial,
            )
            if let host = try? resolve(deviceId: ref.id, hostDevices: hostDevices) {
                guard host.attachable else {
                    throw BarkVisorError.badRequest(
                        host.excludedReason ?? USBDeviceIdentity.massStorageExclusionReason,
                    )
                }
                return passthrough(from: host)
            }
            return USBPassthroughDevice(
                vendorId: device.vendorId,
                productId: device.productId,
                label: device.label,
                serialNumber: serial,
                deviceId: ref.id,
            )
        }

        let vid = USBDeviceIdentity.normalizeHexId(device.vendorId)
        let pid = USBDeviceIdentity.normalizeHexId(device.productId)
        let samePair = hostDevices.filter {
            $0.vendorId == vid && $0.productId == pid && $0.attachable
        }
        if samePair.count > 1 {
            throw BarkVisorError.conflict(
                "Multiple USB devices share \(vid):\(pid); attach by serial or device id",
            )
        }
        if let host = samePair.first {
            return persistUniquePair(device, host: host)
        }
        return USBPassthroughDevice(
            vendorId: vid,
            productId: pid,
            label: device.label,
            serialNumber: nil,
            deviceId: "\(vid):\(pid)",
        )
    }

    private static func persistUniquePair(
        _ device: USBPassthroughDevice,
        host: HostUSBDevice,
    ) -> USBPassthroughDevice {
        if host.serialNumber == nil, USBDeviceIdentity.isBusAddressId(host.id) {
            return USBPassthroughDevice(
                vendorId: host.vendorId,
                productId: host.productId,
                label: device.label ?? host.name,
                serialNumber: nil,
                deviceId: "\(host.vendorId):\(host.productId)",
            )
        }
        return USBPassthroughDevice(
            vendorId: host.vendorId,
            productId: host.productId,
            label: device.label ?? host.name,
            serialNumber: host.serialNumber,
            deviceId: host.id,
        )
    }

    private static func legacyVIDPIDMatch(
        _ device: USBPassthroughDevice,
        host: HostUSBDevice,
    ) -> Bool {
        guard device.serialNumber == nil,
              device.deviceId == nil || device.deviceId == "\(device.vendorId):\(device.productId)"
        else { return false }
        return legacyVIDPIDEquals(device, host: host)
    }

    private static func legacyVIDPIDEquals(_ device: USBPassthroughDevice, host: HostUSBDevice) -> Bool {
        USBDeviceIdentity.normalizeHexId(device.vendorId) == host.vendorId
            && USBDeviceIdentity.normalizeHexId(device.productId) == host.productId
            && device.serialNumber == nil
            && host.serialNumber == nil
    }

    private static func resolvedOrSyntheticHost(
        _ device: USBPassthroughDevice,
        hostDevices: [HostUSBDevice],
    ) -> HostUSBDevice {
        if let deviceId = device.deviceId,
           let host = try? resolve(deviceId: deviceId, hostDevices: hostDevices) {
            return host
        }
        if let serial = USBDeviceIdentity.normalizedSerial(device.serialNumber) {
            let ref = USBDeviceIdentity.make(
                vendorId: device.vendorId, productId: device.productId, serial: serial,
            )
            if let host = try? resolve(deviceId: ref.id, hostDevices: hostDevices) {
                return host
            }
        }
        if let deviceId = device.deviceId, let parsed = USBDeviceIdentity.parse(deviceId) {
            return syntheticHost(from: parsed, fallback: device)
        }
        return HostUSBDevice(
            vendorId: device.vendorId,
            productId: device.productId,
            name: device.label ?? "USB Device",
            manufacturer: nil,
            serialNumber: device.serialNumber,
        )
    }

    private static func syntheticHost(
        from ref: USBDeviceIdentity.Ref,
        fallback: USBPassthroughDevice,
    ) -> HostUSBDevice {
        HostUSBDevice(
            vendorId: ref.vendorId.isEmpty ? fallback.vendorId : ref.vendorId,
            productId: ref.productId.isEmpty ? fallback.productId : ref.productId,
            name: fallback.label ?? "USB Device",
            manufacturer: nil,
            serialNumber: ref.serial ?? fallback.serialNumber,
            bus: ref.bus,
            address: ref.address,
        )
    }
}
