import Foundation

#if os(macOS)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Resolve, claim, and persist PCIe GPU passthrough (PAS-275).
public enum GPUPassthroughService {
    public static let guestOllamaPath = "http://127.0.0.1:11434/v1"

    public static let iommuNotReadyMessage =
        "GPU passthrough needs IOMMU, vfio-pci, KVM, and a GPU in an IOMMU group. This Device is not ready."

    public static let hostGuestExclusiveMessage =
        "This GPU is in use by the host (Ollama). The same card cannot be host and guest."

    public static let hostGPUDrivers: Set<String> = [
        "nvidia", "nvidia_drm", "nvidiafb", "amdgpu", "i915", "nouveau", "xe",
    ]

    public static func isHostGPUDriver(_ driver: String?) -> Bool {
        guard let driver, !driver.isEmpty else { return false }
        return hostGPUDrivers.contains(driver)
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

    public static func passthrough(from host: HostGPUDevice) -> GPUPassthroughDevice {
        GPUPassthroughDevice(
            pciAddress: host.pciAddress,
            iommuGroup: host.iommuGroup,
            vendorId: host.vendorId,
            deviceId: host.deviceId,
            label: host.name,
            groupAddresses: host.groupAddresses,
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
            throw BarkVisorError.badRequest("Invalid GPU PCI address")
        }
        if let found = hostDevices.first(where: { $0.pciAddress == trimmed }) {
            return found
        }
        throw BarkVisorError.notFound("GPU \(trimmed) is not in an IOMMU group")
    }

    public static func resolveAttachable(
        deviceId: String,
        hostDevices: [HostGPUDevice],
    ) throws -> HostGPUDevice {
        let host = try resolve(deviceId: deviceId, hostDevices: hostDevices)
        guard host.attachable else {
            throw BarkVisorError.forbidden(
                host.excludedReason ?? iommuNotReadyMessage,
            )
        }
        return host
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
                throw BarkVisorError.conflict("GPU is attached to \(claim.name)")
            }
            if host.inUseByHost {
                throw BarkVisorError.forbidden(hostGuestExclusiveMessage)
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
                throw BarkVisorError.badRequest("Duplicate GPU \(stored.pciAddress)")
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
                    throw BarkVisorError.badRequest("Invalid GPU PCI address \(addr)")
                }
                if seen.insert(normalized).inserted {
                    ordered.append(normalized)
                }
            }
        }
        return ordered
    }

    public static func liveHostOllamaReachable() -> Bool {
        tcpReachable(host: "127.0.0.1", port: AgentNetworkCage.ollamaPort)
    }

    static func tcpReachable(host: String, port: Int) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Int32(SOCK_STREAM)
        var info: UnsafeMutablePointer<addrinfo>?
        let portText = String(port)
        guard getaddrinfo(host, portText, &hints, &info) == 0, let info else { return false }
        defer { freeaddrinfo(info) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
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
        )
    }
}
