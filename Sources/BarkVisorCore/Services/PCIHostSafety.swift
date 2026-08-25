import Foundation

/// Host PCI addresses that must not be stolen for VFIO (boot disk / remaining uplink).
public struct PCIHostSafety: Equatable, Sendable {
    public var bootDiskAddresses: Set<String>
    public var uplinkAddresses: Set<String>

    public init(
        bootDiskAddresses: Set<String> = [],
        onlyUplinkAddresses: Set<String> = [],
        uplinkAddresses: Set<String> = [],
    ) {
        self.bootDiskAddresses = bootDiskAddresses
        // `onlyUplinkAddresses` is the legacy single-BDF field; merge into all uplinks.
        self.uplinkAddresses = uplinkAddresses.union(onlyUplinkAddresses)
    }

    public static let empty = PCIHostSafety()

    public var onlyUplinkAddresses: Set<String> { uplinkAddresses }

    public func blocks(_ address: String, groupAddresses: [String]) -> String? {
        let addrs = Set([GPUPassthroughService.normalizePCIAddress(address)] + groupAddresses.map {
            GPUPassthroughService.normalizePCIAddress($0)
        })
        if !addrs.isDisjoint(with: bootDiskAddresses) {
            return GPUPassthroughService.bootDiskExclusionReason
        }
        // vfio-pci binds the whole IOMMU group. If that group holds every remaining
        // host uplink, the Device would lose network.
        if !uplinkAddresses.isEmpty, uplinkAddresses.isSubset(of: addrs) {
            return GPUPassthroughService.onlyUplinkExclusionReason
        }
        return nil
    }

    /// Live sysfs/`/proc` occupancy. Empty on macOS (no VFIO).
    public static func live(
        networkPCIAddresses: Set<String>,
        fileManager: FileManager = .default,
    ) -> PCIHostSafety {
        #if os(Linux)
            let mounts = (try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8))
                ?? (try? String(contentsOfFile: "/proc/mounts", encoding: .utf8))
                ?? ""
            let routes = (try? String(contentsOfFile: "/proc/net/route", encoding: .utf8)) ?? ""
            return from(
                mounts: mounts,
                routes: routes,
                sysBlockRoot: "/sys/class/block",
                sysNetRoot: "/sys/class/net",
                networkPCIAddresses: networkPCIAddresses,
                fileManager: fileManager,
            )
        #else
            _ = networkPCIAddresses
            _ = fileManager
            return .empty
        #endif
    }

    public static func from(
        mounts: String,
        routes: String,
        sysBlockRoot: String,
        sysNetRoot: String,
        networkPCIAddresses: Set<String>,
        fileManager: FileManager = .default,
    ) -> PCIHostSafety {
        _ = networkPCIAddresses
        let boot = bootDiskPCIAddresses(
            mounts: mounts, sysBlockRoot: sysBlockRoot, fileManager: fileManager,
        )
        let uplink = defaultRoutePCIAddresses(
            routes: routes, sysNetRoot: sysNetRoot, fileManager: fileManager,
        )
        return PCIHostSafety(
            bootDiskAddresses: boot,
            uplinkAddresses: uplink,
        )
    }

    public static func rootMountSource(fromMounts mounts: String) -> String? {
        for line in mounts.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            if let source = mountinfoRootSource(raw) ?? mountsRootSource(raw) {
                return source
            }
        }
        return nil
    }

    public static func diskName(fromDevicePath path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        if let match = name.range(of: #"^nvme\d+n\d+"#, options: .regularExpression) {
            return String(name[match])
        }
        if let match = name.range(of: #"^mmcblk\d+"#, options: .regularExpression) {
            return String(name[match])
        }
        if let match = name.range(of: #"^[a-z]+"#, options: .regularExpression) {
            let stem = String(name[match])
            let rest = name.dropFirst(stem.count)
            if rest.isEmpty || rest.allSatisfy(\.isNumber) {
                return stem
            }
        }
        return name
    }

    public static func pciAddress(inSysfsPath path: String) -> String? {
        var found: String?
        for part in path.split(separator: "/") {
            let token = String(part)
            if GPUPassthroughService.isPCIAddress(token) {
                found = GPUPassthroughService.normalizePCIAddress(token)
            }
        }
        return found
    }

    public static func defaultRouteInterfaces(fromRoutes routes: String) -> [String] {
        var ifaces: [String] = []
        for line in routes.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard cols.count >= 2 else { continue }
            if cols[0] == "Iface" { continue }
            guard cols[1] == "00000000" else { continue }
            let name = cols[0]
            if name.isEmpty || name == "lo" || name.hasPrefix("lo") && name.dropFirst(2).allSatisfy(\.isNumber) {
                continue
            }
            ifaces.append(name)
        }
        return ifaces
    }

    private static func bootDiskPCIAddresses(
        mounts: String,
        sysBlockRoot: String,
        fileManager: FileManager,
    ) -> Set<String> {
        guard let source = rootMountSource(fromMounts: mounts) else { return [] }
        guard let disk = diskName(fromDevicePath: source) else { return [] }
        return pciAddresses(
            forBlockName: disk,
            sysBlockRoot: sysBlockRoot,
            fileManager: fileManager,
        )
    }

    private static func defaultRoutePCIAddresses(
        routes: String,
        sysNetRoot: String,
        fileManager: FileManager,
    ) -> Set<String> {
        var result: Set<String> = []
        let root = URL(fileURLWithPath: sysNetRoot, isDirectory: true)
        for iface in defaultRouteInterfaces(fromRoutes: routes) {
            let link = root.appendingPathComponent(iface).appendingPathComponent("device")
            let dest = (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) ?? link.path
            if let pci = pciAddress(inSysfsPath: dest) {
                result.insert(pci)
            }
        }
        return result
    }

    private static func pciAddresses(
        forBlockName name: String,
        sysBlockRoot: String,
        fileManager: FileManager,
        depth: Int = 0,
    ) -> Set<String> {
        guard depth < 6, !name.isEmpty else { return [] }
        let block = URL(fileURLWithPath: sysBlockRoot, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        var result: Set<String> = []
        if let dest = try? fileManager.destinationOfSymbolicLink(atPath: block.path),
           let pci = pciAddress(inSysfsPath: dest) {
            result.insert(pci)
        }
        let deviceLink = block.appendingPathComponent("device")
        if let dest = try? fileManager.destinationOfSymbolicLink(atPath: deviceLink.path),
           let pci = pciAddress(inSysfsPath: dest) {
            result.insert(pci)
        }
        let slaves = block.appendingPathComponent("slaves")
        let slaveNames = (try? fileManager.contentsOfDirectory(atPath: slaves.path)) ?? []
        for slave in slaveNames {
            guard let child = diskName(fromDevicePath: slave) else { continue }
            result.formUnion(
                pciAddresses(
                    forBlockName: child,
                    sysBlockRoot: sysBlockRoot,
                    fileManager: fileManager,
                    depth: depth + 1,
                ),
            )
        }
        return result
    }

    private static func mountinfoRootSource(_ line: String) -> String? {
        guard let sep = line.range(of: " - ") else { return nil }
        let left = line[..<sep.lowerBound].split(whereSeparator: { $0.isWhitespace })
        guard left.count >= 5, String(left[4]) == "/" else { return nil }
        let right = line[sep.upperBound...].split(whereSeparator: { $0.isWhitespace })
        guard right.count >= 2 else { return nil }
        return String(right[1])
    }

    private static func mountsRootSource(_ line: String) -> String? {
        let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard cols.count >= 2, cols[1] == "/" else { return nil }
        return cols[0]
    }
}
