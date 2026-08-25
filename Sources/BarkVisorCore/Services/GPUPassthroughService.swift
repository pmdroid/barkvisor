import Foundation

/// Resolve, claim, and persist PCIe GPU passthrough (PAS-275).
public enum GPUPassthroughService {
    public static let guestOllamaPath = "http://127.0.0.1:11434/v1"

    public static let iommuNotReadyMessage =
        "GPU passthrough needs IOMMU, vfio-pci, KVM, and a GPU in an IOMMU group. This Device is not ready."

    public static let pciPassthroughNotReadyMessage =
        "PCI passthrough needs IOMMU, vfio-pci, and KVM. This Device is not ready."

    public static let hostGuestExclusiveMessage =
        "This GPU is bound to a host driver. Attaching it takes the card from the host. The same card cannot be host and guest."

    public static let hostPCIExclusiveMessage =
        "This PCI device is bound to a host driver. Attaching it takes the device from the host."

    public static let bootDiskExclusionReason =
        "This is the host boot disk. Passing it through would remove the Device's system disk."

    public static let onlyUplinkExclusionReason =
        "Passing this through would take the Device's remaining uplink."

    public static let pciBridgeExclusionReason =
        "PCI bridges cannot be passed through."

    public static let hostGPUDrivers: Set<String> = [
        "nvidia", "nvidia_drm", "nvidiafb", "amdgpu", "i915", "nouveau", "xe",
    ]

    public static func isHostGPUDriver(_ driver: String?) -> Bool {
        guard let driver, !driver.isEmpty else { return false }
        return hostGPUDrivers.contains(driver)
    }

    /// vfio-pci is bound at QEMU start, not hot-plugged. Detach is only safe when stopped.
    public static func canDetach(state: String) -> Bool {
        state == "stopped" || state == "error"
    }

    public static func assertCanDetach(state: String) throws {
        guard canDetach(state: state) else {
            throw BarkVisorError.conflict(
                "GPU passthrough cannot be detached while the Workload is running",
            )
        }
    }

    public static func normalizePCIAddress(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isPCIAddress(_ raw: String) -> Bool {
        let value = normalizePCIAddress(raw)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let funcParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard funcParts.count == 2 else { return false }
        let domain = parts[0], bus = parts[1], slot = funcParts[0], fn = funcParts[1]
        guard domain.count == 4, bus.count == 2, slot.count == 2, fn.count == 1 else {
            return false
        }
        let hex = domain + bus + slot
        guard hex.allSatisfy(\.isHexDigit) else { return false }
        guard let fnChar = fn.first, fnChar >= "0", fnChar <= "7" else { return false }
        return true
    }

    public static func normalizeHexId(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("0x") { value = String(value.dropFirst(2)) }
        return value
    }

    public static func normalizePCIClass(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = VFIOProbe.normalizedPCIClass(raw)
        return hex.isEmpty ? nil : hex
    }

    public static func pciClassLabel(_ raw: String) -> String {
        switch VFIOProbe.pciBaseClass(raw) {
        case "01": return "Mass storage"
        case "02": return "Network"
        case "03": return "Display"
        case "04": return "Multimedia"
        case "05": return "Memory"
        case "06": return "Bridge"
        case "07": return "Communication"
        case "08": return "System"
        case "0c": return "Serial bus"
        case "0d": return "Wireless"
        case "12": return "Processing accelerator"
        default:
            let base = VFIOProbe.pciBaseClass(raw)
            return base.isEmpty ? "PCI" : "Class \(base)"
        }
    }

    public static func isDisplayDevice(_ device: GPUPassthroughDevice) -> Bool {
        guard let pciClass = device.pciClass else { return true }
        return VFIOProbe.isDisplayClass(pciClass)
    }

    public static func hasDisplayGPU(_ devices: [GPUPassthroughDevice]?) -> Bool {
        (devices ?? []).contains(where: isDisplayDevice)
    }

    public static func displayName(vendorId: String, deviceId: String, driver: String?) -> String {
        let vendor = normalizeHexId(vendorId)
        let vendorName = switch vendor {
        case "10de": "NVIDIA"
        case "1002": "AMD"
        case "8086": "Intel"
        default: "GPU"
        }
        let extra = driver.map { " (\($0))" } ?? ""
        return "\(vendorName) \(normalizeHexId(deviceId))\(extra)"
    }

    public static func pciDeviceName(
        vendorId: String,
        deviceId: String,
        pciClass: String?,
        driver: String?,
    ) -> String {
        if let pciClass, VFIOProbe.isDisplayClass(pciClass) {
            return displayName(vendorId: vendorId, deviceId: deviceId, driver: driver)
        }
        let classLabel = pciClassLabel(pciClass ?? "")
        let vendor = switch normalizeHexId(vendorId) {
        case "10de": "NVIDIA"
        case "1002": "AMD"
        case "8086": "Intel"
        default: normalizeHexId(vendorId).isEmpty ? "PCI" : normalizeHexId(vendorId)
        }
        let extra = driver.map { " (\($0))" } ?? ""
        return "\(classLabel) \(vendor) \(normalizeHexId(deviceId))\(extra)"
    }

    public static func passthrough(from host: HostGPUDevice) -> GPUPassthroughDevice {
        GPUPassthroughDevice(
            pciAddress: host.pciAddress,
            iommuGroup: host.iommuGroup,
            vendorId: host.vendorId,
            deviceId: host.deviceId,
            label: host.name,
            groupAddresses: host.groupAddresses,
            pciClass: host.pciClass,
        )
    }

    public static func workload(from device: GPUPassthroughDevice) -> WorkloadGPUDevice {
        WorkloadGPUDevice(
            pciAddress: device.pciAddress,
            iommuGroup: device.iommuGroup,
            vendorId: device.vendorId,
            deviceId: device.deviceId,
            label: device.label,
            groupAddresses: device.groupAddresses,
            pciClass: device.pciClass,
        )
    }

    public static func passthrough(from spec: WorkloadGPUDevice) -> GPUPassthroughDevice {
        GPUPassthroughDevice(
            pciAddress: spec.pciAddress,
            iommuGroup: spec.iommuGroup,
            vendorId: spec.vendorId,
            deviceId: spec.deviceId,
            label: spec.label,
            groupAddresses: spec.groupAddresses,
            pciClass: spec.pciClass,
        )
    }

    public static func matches(_ device: GPUPassthroughDevice, host: HostGPUDevice) -> Bool {
        if device.pciAddress == host.pciAddress { return true }
        if !device.iommuGroup.isEmpty, device.iommuGroup == host.iommuGroup { return true }
        if device.groupAddresses.contains(host.pciAddress) { return true }
        return host.groupAddresses.contains(device.pciAddress)
    }

    public static func resolve(
        deviceId: String,
        hostDevices: [HostGPUDevice],
    ) throws -> HostGPUDevice {
        let trimmed = normalizePCIAddress(deviceId)
        guard isPCIAddress(trimmed) else {
            throw BarkVisorError.badRequest("Invalid PCI address")
        }
        if let found = hostDevices.first(where: { $0.pciAddress == trimmed }) {
            return found
        }
        throw BarkVisorError.notFound("PCI device \(trimmed) is not in an IOMMU group")
    }

    public static func resolveAttachable(
        deviceId: String,
        hostDevices: [HostGPUDevice],
    ) throws -> HostGPUDevice {
        let host = try resolve(deviceId: deviceId, hostDevices: hostDevices)
        guard host.attachable else {
            throw BarkVisorError.forbidden(
                host.excludedReason ?? notReadyMessage(for: host),
            )
        }
        return host
    }

    public static func isDisplayHost(_ host: HostGPUDevice) -> Bool {
        guard let pciClass = host.pciClass else { return true }
        return VFIOProbe.isDisplayClass(pciClass)
    }

    public static func notReadyMessage(for host: HostGPUDevice) -> String {
        isDisplayHost(host) ? iommuNotReadyMessage : pciPassthroughNotReadyMessage
    }

    public static func claimedMessage(workloadName: String, host: HostGPUDevice) -> String {
        let kind = isDisplayHost(host) ? "GPU" : "PCI device"
        return "\(kind) is attached to \(workloadName)"
    }

    public static func claimedBy(
        host: HostGPUDevice,
        vms: [VM],
        excludingVMId: String? = nil,
    ) -> (id: String, name: String)? {
        for vm in vms {
            if vm.id == excludingVMId { continue }
            if vm.decodedGPUDevices.contains(where: { matches($0, host: host) }) {
                return (id: vm.id, name: vm.name)
            }
        }
        return nil
    }

    public static func assertUnclaimed(
        devices: [GPUPassthroughDevice],
        vms: [VM],
        excludingVMId: String? = nil,
        hostDevices: [HostGPUDevice] = [],
    ) throws {
        for device in devices {
            let host = hostDevices.first { matches(device, host: $0) }
                ?? syntheticHost(device)
            if let claim = claimedBy(host: host, vms: vms, excludingVMId: excludingVMId) {
                throw BarkVisorError.conflict(claimedMessage(workloadName: claim.name, host: host))
            }
        }
    }

    public static func contains(_ devices: [GPUPassthroughDevice], host: HostGPUDevice) -> Bool {
        devices.contains { matches($0, host: host) }
    }

    public static func removing(
        _ devices: [GPUPassthroughDevice],
        deviceId: String,
    ) -> [GPUPassthroughDevice] {
        let trimmed = normalizePCIAddress(deviceId)
        return devices.filter { device in
            if device.pciAddress == trimmed { return false }
            if device.groupAddresses.contains(trimmed) { return false }
            return true
        }
    }

    public static func normalizeForPersist(
        _ devices: [GPUPassthroughDevice]?,
        hostDevices: [HostGPUDevice],
    ) throws -> [GPUPassthroughDevice]? {
        guard let devices else { return nil }
        if devices.isEmpty { return [] }
        var result: [GPUPassthroughDevice] = []
        for device in devices {
            let host = try resolveAttachable(deviceId: device.pciAddress, hostDevices: hostDevices)
            let stored = passthrough(from: host)
            if result.contains(where: { $0.pciAddress == stored.pciAddress }) {
                throw BarkVisorError.badRequest("Duplicate PCI device \(stored.pciAddress)")
            }
            if result.contains(where: { $0.iommuGroup == stored.iommuGroup }) {
                throw BarkVisorError.badRequest(
                    "IOMMU group \(stored.iommuGroup) is already attached",
                )
            }
            result.append(stored)
        }
        return result
    }

    public static func qemuHostAddresses(from devices: [GPUPassthroughDevice]) throws -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for device in devices {
            let addrs = device.groupAddresses.isEmpty ? [device.pciAddress] : device.groupAddresses
            for addr in addrs {
                let normalized = normalizePCIAddress(addr)
                guard isPCIAddress(normalized) else {
                    throw BarkVisorError.badRequest("Invalid PCI address \(addr)")
                }
                if seen.insert(normalized).inserted {
                    ordered.append(normalized)
                }
            }
        }
        return ordered
    }

    public static func releaseVFIO(
        _ devices: [GPUPassthroughDevice],
        paths: VFIOBindPaths = .linuxHost,
        sysfs: VFIOSysfs? = nil,
    ) {
        guard !devices.isEmpty else { return }
        let addresses = (try? qemuHostAddresses(from: devices)) ?? []
        guard !addresses.isEmpty else { return }
        do {
            try VFIOBinder.unbind(addresses: addresses, paths: paths, sysfs: sysfs)
        } catch {
            Log.vm.warning("vfio-pci unbind failed: \(error.localizedDescription)")
        }
    }

    private static func syntheticHost(_ device: GPUPassthroughDevice) -> HostGPUDevice {
        HostGPUDevice(
            pciAddress: device.pciAddress,
            iommuGroup: device.iommuGroup,
            vendorId: device.vendorId,
            deviceId: device.deviceId,
            name: device.label ?? device.pciAddress,
            driver: nil,
            vfioBound: false,
            inUseByHost: false,
            attachable: true,
            excludedReason: nil,
            groupAddresses: device.groupAddresses,
            pciClass: device.pciClass,
        )
    }
}
