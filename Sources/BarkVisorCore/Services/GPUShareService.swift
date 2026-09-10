import Foundation

public struct HostGPUShareDevice: Codable, Equatable, Sendable {
    public static let kindDRM = "drm"
    public static let kindNVIDIA = "nvidia"

    public let id: String
    public let kind: String
    public let name: String
    public let label: String
    public let driver: String?
    public let pciAddress: String?
    public let renderNodes: [String]
    public let cardNodes: [String]
    public let nvidiaUUID: String?
    public let vfioBound: Bool
    public let attachable: Bool
    public let excludedReason: String?
    public let claimedByVMId: String?
    public let claimedByVMName: String?

    public init(
        id: String,
        kind: String,
        name: String,
        label: String,
        driver: String? = nil,
        pciAddress: String? = nil,
        renderNodes: [String] = [],
        cardNodes: [String] = [],
        nvidiaUUID: String? = nil,
        vfioBound: Bool = false,
        attachable: Bool = false,
        excludedReason: String? = nil,
        claimedByVMId: String? = nil,
        claimedByVMName: String? = nil,
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.label = label
        self.driver = driver
        self.pciAddress = pciAddress.map { GPUPassthroughService.normalizePCIAddress($0) }
        self.renderNodes = renderNodes
        self.cardNodes = cardNodes
        self.nvidiaUUID = nvidiaUUID
        self.vfioBound = vfioBound
        self.attachable = attachable
        self.excludedReason = excludedReason
        self.claimedByVMId = claimedByVMId
        self.claimedByVMName = claimedByVMName
    }

    public var driPaths: [String] {
        renderNodes + cardNodes
    }
}

public struct GPUShareAttach: Equatable, Sendable {
    public var driDevices: [String]
    public var nvidiaUUIDs: [String]
    public var nvidiaRuntime: Bool

    public static let empty = GPUShareAttach(driDevices: [], nvidiaUUIDs: [], nvidiaRuntime: false)

    public init(driDevices: [String], nvidiaUUIDs: [String], nvidiaRuntime: Bool) {
        self.driDevices = driDevices
        self.nvidiaUUIDs = nvidiaUUIDs
        self.nvidiaRuntime = nvidiaRuntime
    }

    public var isEmpty: Bool {
        driDevices.isEmpty && nvidiaUUIDs.isEmpty
    }
}

public struct GPUSharePaths: Equatable, Sendable {
    public var driDir: String
    public var drmClass: String
    public var pciDevices: String

    public static let linuxHost = GPUSharePaths(
        driDir: "/dev/dri",
        drmClass: "/sys/class/drm",
        pciDevices: "/sys/bus/pci/devices",
    )

    public init(driDir: String, drmClass: String, pciDevices: String) {
        self.driDir = driDir
        self.drmClass = drmClass
        self.pciDevices = pciDevices
    }
}

public struct NVIDIAShareGPU: Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var pciAddress: String?

    public init(uuid: String, name: String, pciAddress: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.pciAddress = pciAddress.flatMap(GPUShareService.normalizeNVIDIABusID)
    }
}

public struct NVIDIAShareFacts: Equatable, Sendable {
    public var present: Bool
    public var toolkitPresent: Bool
    public var gpus: [NVIDIAShareGPU]

    public static let empty = NVIDIAShareFacts(present: false, toolkitPresent: false, gpus: [])

    public init(present: Bool, toolkitPresent: Bool, gpus: [NVIDIAShareGPU] = []) {
        self.present = present
        self.toolkitPresent = toolkitPresent
        self.gpus = gpus
    }
}

public enum GPUShareService {
    public static let vfioBoundMessage = "Bound to vfio-pci"
    public static let toolkitMissingMessage =
        "Install nvidia-container-toolkit to share this NVIDIA GPU with Docker."
    public static let claimedMessagePrefix = "Attached to "

    public nonisolated(unsafe) static var listProvider: (@Sendable ([VM]) -> [HostGPUShareDevice])?
    public nonisolated(unsafe) static var nvidiaFactsProvider: (@Sendable () -> NVIDIAShareFacts)?

    public static func list(vms: [VM] = [], fileManager: FileManager = .default) -> [HostGPUShareDevice] {
        if let listProvider {
            return listProvider(vms)
        }
        #if os(Linux)
            return list(
                from: .linuxHost,
                nvidia: nvidiaFactsProvider?() ?? NVIDIAShareProbe.live(),
                vms: vms,
                fileManager: fileManager,
            )
        #else
            _ = fileManager
            _ = vms
            return []
        #endif
    }

    public static func list(
        from paths: GPUSharePaths,
        nvidia: NVIDIAShareFacts,
        vms: [VM] = [],
        fileManager: FileManager = .default,
    ) -> [HostGPUShareDevice] {
        let pci = loadPCI(from: paths, fileManager: fileManager)
        let drm = loadDRM(from: paths, fileManager: fileManager)
        var rows: [HostGPUShareDevice] = []
        var seen = Set<String>()

        for node in drm {
            let info = pci[node.pci]
            if isNVIDIADriver(info?.driver) {
                continue
            }
            seen.insert(node.pci)
            rows.append(projectDRM(node, info: info, vms: vms))
        }

        for gpu in nvidia.gpus {
            if let address = gpu.pciAddress, pci[address]?.driver == "vfio-pci" {
                continue
            }
            if let address = gpu.pciAddress {
                seen.insert(address)
            }
            rows.append(projectNVIDIA(gpu, toolkitPresent: nvidia.toolkitPresent, pci: pci, vms: vms))
        }

        for (bdf, info) in pci {
            guard VFIOProbe.isDisplayClass(info.pciClass) else { continue }
            guard info.driver == "vfio-pci" else { continue }
            if seen.contains(bdf) { continue }
            seen.insert(bdf)
            rows.append(projectVFIO(bdf, info: info, vms: vms))
        }

        return rows.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public static func validate(
        _ selected: [WorkloadGPUShare],
        inventory: [HostGPUShareDevice]? = nil,
    ) throws {
        if selected.isEmpty { return }
        let cards = inventory ?? list()
        for item in selected {
            if item.id.isEmpty {
                throw BarkVisorError.badRequest("spec.gpuShare.id is required")
            }
            guard let card = cards.first(where: { $0.id == item.id }) else {
                throw BarkVisorError.badRequest("unknown GPU share \(item.id)")
            }
            if !card.attachable {
                throw BarkVisorError.badRequest(
                    card.excludedReason ?? "GPU \(item.id) is not attachable",
                )
            }
        }
    }

    public static func attach(
        selected: [WorkloadGPUShare],
        inventory: [HostGPUShareDevice],
    ) throws -> GPUShareAttach {
        try validate(selected, inventory: inventory)
        var dri: [String] = []
        var uuids: [String] = []
        for item in selected {
            guard let card = inventory.first(where: { $0.id == item.id }) else { continue }
            for path in card.driPaths where isDRIPath(path) {
                dri.append(path)
            }
            if let uuid = card.nvidiaUUID, !uuid.isEmpty {
                uuids.append(uuid)
            }
        }
        let uniqueDRI = Array(Set(dri)).sorted()
        let uniqueUUID = Array(Set(uuids)).sorted()
        return GPUShareAttach(
            driDevices: uniqueDRI,
            nvidiaUUIDs: uniqueUUID,
            nvidiaRuntime: !uniqueUUID.isEmpty,
        )
    }

    public static func isDRIPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let prefix = "/dev/dri/"
        guard url.path.hasPrefix(prefix) else { return false }
        let name = url.lastPathComponent
        if name.contains("..") || name.contains("/") { return false }
        return name.hasPrefix("renderD") || name.hasPrefix("card")
    }

    public static func normalizeNVIDIABusID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var domain = String(parts[0])
        if domain.hasPrefix("0x") { domain = String(domain.dropFirst(2)) }
        if domain.count == 8 { domain = String(domain.suffix(4)) }
        let address = "\(domain):\(parts[1]):\(parts[2])"
        guard GPUPassthroughService.isPCIAddress(address) else { return nil }
        return GPUPassthroughService.normalizePCIAddress(address)
    }

    private struct PCIInfo {
        var vendorId: String
        var deviceId: String
        var pciClass: String
        var driver: String?
    }

    private struct DRMNode {
        var pci: String
        var render: [String]
        var card: [String]
    }

    private static func loadPCI(
        from paths: GPUSharePaths,
        fileManager: FileManager,
    ) -> [String: PCIInfo] {
        let entries = (try? fileManager.contentsOfDirectory(atPath: paths.pciDevices)) ?? []
        var out: [String: PCIInfo] = [:]
        for name in entries {
            guard GPUPassthroughService.isPCIAddress(name) else { continue }
            let dir = URL(fileURLWithPath: paths.pciDevices).appendingPathComponent(name)
            let vendor = readSysfs(dir.appendingPathComponent("vendor"), fileManager: fileManager)
            let device = readSysfs(dir.appendingPathComponent("device"), fileManager: fileManager)
            let pciClass = readSysfs(dir.appendingPathComponent("class"), fileManager: fileManager)
            let driver = readDriver(dir.appendingPathComponent("driver").path, fileManager: fileManager)
            out[GPUPassthroughService.normalizePCIAddress(name)] = PCIInfo(
                vendorId: GPUPassthroughService.normalizeHexId(vendor),
                deviceId: GPUPassthroughService.normalizeHexId(device),
                pciClass: VFIOProbe.normalizedPCIClass(pciClass),
                driver: driver,
            )
        }
        return out
    }

    private static func loadDRM(
        from paths: GPUSharePaths,
        fileManager: FileManager,
    ) -> [DRMNode] {
        let entries = (try? fileManager.contentsOfDirectory(atPath: paths.drmClass)) ?? []
        var grouped: [String: DRMNode] = [:]
        for name in entries {
            let isRender = name.hasPrefix("renderD")
            let isCard = name.hasPrefix("card") && !name.contains("-")
            guard isRender || isCard else { continue }
            let link = URL(fileURLWithPath: paths.drmClass)
                .appendingPathComponent(name)
                .appendingPathComponent("device")
            guard let pci = pciAddress(fromDeviceLink: link.path, fileManager: fileManager) else {
                continue
            }
            let host = URL(fileURLWithPath: paths.driDir).appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: host) else { continue }
            var node = grouped[pci] ?? DRMNode(pci: pci, render: [], card: [])
            if isRender {
                node.render.append(host)
            } else {
                node.card.append(host)
            }
            grouped[pci] = node
        }
        return grouped.values.filter { !$0.render.isEmpty }.map { node in
            DRMNode(pci: node.pci, render: node.render.sorted(), card: node.card.sorted())
        }
    }

    private static func projectDRM(
        _ node: DRMNode,
        info: PCIInfo?,
        vms: [VM],
    ) -> HostGPUShareDevice {
        let driver = info?.driver
        let vfio = driver == "vfio-pci"
        let claim = claimed(pciAddress: node.pci, vms: vms)
        let name = GPUPassthroughService.displayName(
            vendorId: info?.vendorId ?? "",
            deviceId: info?.deviceId ?? "",
            driver: driver,
        )
        let renderName = URL(fileURLWithPath: node.render[0]).lastPathComponent
        var attachable = !vfio && claim == nil
        var reason: String?
        if let claim {
            attachable = false
            reason = claimedMessagePrefix + claim.name
        } else if vfio {
            attachable = false
            reason = vfioBoundMessage
        }
        return HostGPUShareDevice(
            id: node.pci,
            kind: HostGPUShareDevice.kindDRM,
            name: name,
            label: "\(name) (\(renderName))",
            driver: driver,
            pciAddress: node.pci,
            renderNodes: node.render,
            cardNodes: node.card,
            nvidiaUUID: nil,
            vfioBound: vfio,
            attachable: attachable,
            excludedReason: reason,
            claimedByVMId: claim?.id,
            claimedByVMName: claim?.name,
        )
    }

    private static func projectNVIDIA(
        _ gpu: NVIDIAShareGPU,
        toolkitPresent: Bool,
        pci: [String: PCIInfo],
        vms: [VM],
    ) -> HostGPUShareDevice {
        let info = gpu.pciAddress.flatMap { pci[$0] }
        let vfio = info?.driver == "vfio-pci"
        let claim = claimed(pciAddress: gpu.pciAddress, vms: vms)
        var attachable = toolkitPresent && !vfio && claim == nil
        var reason: String?
        if let claim {
            attachable = false
            reason = claimedMessagePrefix + claim.name
        } else if vfio {
            attachable = false
            reason = vfioBoundMessage
        } else if !toolkitPresent {
            attachable = false
            reason = toolkitMissingMessage
        }
        let name = gpu.name.isEmpty ? "NVIDIA" : gpu.name
        return HostGPUShareDevice(
            id: gpu.uuid,
            kind: HostGPUShareDevice.kindNVIDIA,
            name: name,
            label: "\(name) (\(gpu.uuid))",
            driver: info?.driver ?? "nvidia",
            pciAddress: gpu.pciAddress,
            renderNodes: [],
            cardNodes: [],
            nvidiaUUID: gpu.uuid,
            vfioBound: vfio,
            attachable: attachable,
            excludedReason: reason,
            claimedByVMId: claim?.id,
            claimedByVMName: claim?.name,
        )
    }

    private static func projectVFIO(
        _ bdf: String,
        info: PCIInfo,
        vms: [VM],
    ) -> HostGPUShareDevice {
        let claim = claimed(pciAddress: bdf, vms: vms)
        let name = GPUPassthroughService.displayName(
            vendorId: info.vendorId,
            deviceId: info.deviceId,
            driver: info.driver,
        )
        let reason = claim.map { claimedMessagePrefix + $0.name } ?? vfioBoundMessage
        return HostGPUShareDevice(
            id: bdf,
            kind: HostGPUShareDevice.kindDRM,
            name: name,
            label: "\(name) (vfio-pci)",
            driver: info.driver,
            pciAddress: bdf,
            renderNodes: [],
            cardNodes: [],
            nvidiaUUID: nil,
            vfioBound: true,
            attachable: false,
            excludedReason: reason,
            claimedByVMId: claim?.id,
            claimedByVMName: claim?.name,
        )
    }

    private static func claimed(pciAddress: String?, vms: [VM]) -> (id: String, name: String)? {
        guard let pciAddress else { return nil }
        let address = GPUPassthroughService.normalizePCIAddress(pciAddress)
        for vm in vms where vm.decodedGPUDevices.contains(where: { $0.pciAddress == address }) {
            return (id: vm.id, name: vm.name)
        }
        return nil
    }

    private static func isNVIDIADriver(_ driver: String?) -> Bool {
        guard let driver else { return false }
        return driver == "nvidia" || driver == "nvidia_drm" || driver == "nvidiafb"
    }

    private static func pciAddress(fromDeviceLink path: String, fileManager: FileManager) -> String? {
        let dest: String = if let linked = try? fileManager.destinationOfSymbolicLink(atPath: path) {
            linked
        } else {
            path
        }
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        let resolved = URL(fileURLWithPath: dest, relativeTo: base).standardizedFileURL.lastPathComponent
        if GPUPassthroughService.isPCIAddress(resolved) {
            return GPUPassthroughService.normalizePCIAddress(resolved)
        }
        let name = URL(fileURLWithPath: dest).lastPathComponent
        if GPUPassthroughService.isPCIAddress(name) {
            return GPUPassthroughService.normalizePCIAddress(name)
        }
        return nil
    }

    private static func readSysfs(_ url: URL, fileManager: FileManager) -> String {
        guard let data = fileManager.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readDriver(_ path: String, fileManager: FileManager) -> String? {
        guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: path) else { return nil }
        let name = URL(fileURLWithPath: dest).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
