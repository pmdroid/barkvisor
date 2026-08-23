import Foundation

/// Sysfs paths used to bind a PCI device to vfio-pci (PAS-275).
public struct VFIOBindPaths: Sendable, Equatable {
    public var devicesRoot: String
    public var vfioPciDriver: String

    public init(devicesRoot: String, vfioPciDriver: String) {
        self.devicesRoot = devicesRoot
        self.vfioPciDriver = vfioPciDriver
    }

    public static let linuxHost = VFIOBindPaths(
        devicesRoot: "/sys/bus/pci/devices",
        vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
    )
}

/// Bind PCI addresses to vfio-pci. Fail closed if sysfs writes do not land.
public enum VFIOBinder {
    public static func bind(
        addresses: [String],
        paths: VFIOBindPaths = .linuxHost,
        fileManager: FileManager = .default,
    ) throws {
        for raw in addresses {
            let address = GPUPassthroughService.normalizePCIAddress(raw)
            guard GPUPassthroughService.isPCIAddress(address) else {
                throw BarkVisorError.badRequest("Invalid GPU PCI address \(raw)")
            }
            try bindOne(address: address, paths: paths, fileManager: fileManager)
        }
    }

    private static func bindOne(
        address: String,
        paths: VFIOBindPaths,
        fileManager: FileManager,
    ) throws {
        let deviceDir = URL(fileURLWithPath: paths.devicesRoot, isDirectory: true)
            .appendingPathComponent(address, isDirectory: true)
        guard fileManager.fileExists(atPath: deviceDir.path) else {
            throw BarkVisorError.forbidden(
                "GPU \(address) is missing from sysfs; refusing vfio bind",
            )
        }
        let driverLink = deviceDir.appendingPathComponent("driver")
        let current = (try? fileManager.destinationOfSymbolicLink(atPath: driverLink.path))
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        if current == "vfio-pci" { return }

        let override = deviceDir.appendingPathComponent("driver_override")
        try write("vfio-pci\n", to: override, fileManager: fileManager)

        if current != nil {
            let unbind = driverLink.appendingPathComponent("unbind")
            try write("\(address)\n", to: unbind, fileManager: fileManager)
        }

        let bind = URL(fileURLWithPath: paths.vfioPciDriver, isDirectory: true)
            .appendingPathComponent("bind")
        try write("\(address)\n", to: bind, fileManager: fileManager)

        let bound = (try? fileManager.destinationOfSymbolicLink(atPath: driverLink.path))
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        if bound == "vfio-pci" { return }
        let bindText = (try? String(contentsOf: bind, encoding: .utf8)) ?? ""
        guard bindText.contains(address) else {
            throw BarkVisorError.forbidden(
                "GPU \(address) did not bind to vfio-pci; refusing QEMU start",
            )
        }
    }

    private static func write(_ text: String, to url: URL, fileManager: FileManager) throws {
        do {
            try text.write(to: url, atomically: false, encoding: .utf8)
        } catch {
            throw BarkVisorError.forbidden(
                "vfio-pci sysfs write failed at \(url.lastPathComponent): \(error.localizedDescription)",
            )
        }
        _ = fileManager
    }
}
