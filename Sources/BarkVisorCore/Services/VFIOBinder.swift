import Foundation

/// Sysfs paths used to bind a PCI device to vfio-pci (PAS-275).
public struct VFIOBindPaths: Sendable, Equatable {
    public var devicesRoot: String
    public var vfioPciDriver: String
    public var driversProbe: String

    public init(devicesRoot: String, vfioPciDriver: String, driversProbe: String) {
        self.devicesRoot = devicesRoot
        self.vfioPciDriver = vfioPciDriver
        self.driversProbe = driversProbe
    }

    public static let linuxHost = VFIOBindPaths(
        devicesRoot: "/sys/bus/pci/devices",
        vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
        driversProbe: "/sys/bus/pci/drivers_probe",
    )
}

/// Testable sysfs I/O for vfio bind/unbind. Bind and unbind nodes are write-only
/// on Linux; verification must not read them.
public struct VFIOSysfs: Sendable {
    public var fileExists: @Sendable (String) -> Bool
    public var currentDriver: @Sendable (String) -> String?
    public var write: @Sendable (String, String) throws -> Void

    public init(
        fileExists: @escaping @Sendable (String) -> Bool,
        currentDriver: @escaping @Sendable (String) -> String?,
        write: @escaping @Sendable (String, String) throws -> Void,
    ) {
        self.fileExists = fileExists
        self.currentDriver = currentDriver
        self.write = write
    }

    public static func posix(
        devicesRoot: String = VFIOBindPaths.linuxHost.devicesRoot,
    ) -> VFIOSysfs {
        VFIOSysfs(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            currentDriver: { address in
                let driverLink = URL(fileURLWithPath: devicesRoot, isDirectory: true)
                    .appendingPathComponent(address, isDirectory: true)
                    .appendingPathComponent("driver")
                    .path
                return (try? FileManager.default.destinationOfSymbolicLink(atPath: driverLink))
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
            },
            write: { text, path in
                try text.write(to: URL(fileURLWithPath: path), atomically: false, encoding: .utf8)
            },
        )
    }
}

/// Bind PCI addresses to vfio-pci. Fail closed if the driver symlink does not land.
public enum VFIOBinder {
    public static func bind(
        addresses: [String],
        paths: VFIOBindPaths = .linuxHost,
        fileManager: FileManager = .default,
        sysfs: VFIOSysfs? = nil,
    ) throws {
        _ = fileManager
        let io = sysfs ?? .posix(devicesRoot: paths.devicesRoot)
        var boundThisCall: [String] = []
        do {
            for raw in addresses {
                let address = GPUPassthroughService.normalizePCIAddress(raw)
                guard GPUPassthroughService.isPCIAddress(address) else {
                    throw BarkVisorError.badRequest("Invalid PCI address \(raw)")
                }
                let alreadyBound = io.currentDriver(address) == "vfio-pci"
                try bindOne(address: address, paths: paths, sysfs: io)
                if !alreadyBound {
                    boundThisCall.append(address)
                }
            }
        } catch {
            if !boundThisCall.isEmpty {
                try? unbind(addresses: boundThisCall, paths: paths, sysfs: io)
            }
            throw error
        }
    }

    public static func unbind(
        addresses: [String],
        paths: VFIOBindPaths = .linuxHost,
        fileManager: FileManager = .default,
        sysfs: VFIOSysfs? = nil,
    ) throws {
        _ = fileManager
        let io = sysfs ?? .posix(devicesRoot: paths.devicesRoot)
        for raw in addresses {
            let address = GPUPassthroughService.normalizePCIAddress(raw)
            guard GPUPassthroughService.isPCIAddress(address) else {
                throw BarkVisorError.badRequest("Invalid PCI address \(raw)")
            }
            try unbindOne(address: address, paths: paths, sysfs: io)
        }
    }

    private static func bindOne(address: String, paths: VFIOBindPaths, sysfs: VFIOSysfs) throws {
        let deviceDir = URL(fileURLWithPath: paths.devicesRoot, isDirectory: true)
            .appendingPathComponent(address, isDirectory: true)
        try requireSysfsNode(
            deviceDir.path,
            operation: "bind",
            cause: "PCI device \(address) is missing from sysfs",
            sysfs: sysfs,
        )
        if sysfs.currentDriver(address) == "vfio-pci" { return }

        try requireSysfsNode(
            deviceDir.appendingPathComponent("iommu_group").path,
            operation: "bind",
            cause: "PCI device \(address) has no IOMMU group; the IOMMU is disabled or unsupported on this Device",
            sysfs: sysfs,
        )
        try requireSysfsNode(
            paths.vfioPciDriver,
            operation: "bind",
            cause: "the vfio-pci kernel module is not loaded",
            sysfs: sysfs,
        )
        let bind = URL(fileURLWithPath: paths.vfioPciDriver, isDirectory: true)
            .appendingPathComponent("bind")
            .path
        try requireSysfsNode(
            bind,
            operation: "bind",
            cause: "the vfio-pci bind node is missing from sysfs",
            sysfs: sysfs,
        )

        let override = deviceDir.appendingPathComponent("driver_override").path
        try requireSysfsNode(
            override,
            operation: "bind",
            cause: "this kernel does not support driver_override",
            sysfs: sysfs,
        )
        try write("vfio-pci\n", to: override, sysfs: sysfs)

        if sysfs.currentDriver(address) != nil {
            let unbind = deviceDir.appendingPathComponent("driver").appendingPathComponent("unbind").path
            try requireSysfsNode(
                unbind,
                operation: "bind",
                cause: "PCI device \(address) has no host driver to unbind from",
                sysfs: sysfs,
            )
            try write("\(address)\n", to: unbind, sysfs: sysfs)
        }

        try write("\(address)\n", to: bind, sysfs: sysfs)

        guard sysfs.currentDriver(address) == "vfio-pci" else {
            throw BarkVisorError.forbidden(
                "GPU \(address) did not bind to vfio-pci; refusing QEMU start",
            )
        }
    }

    private static func unbindOne(address: String, paths: VFIOBindPaths, sysfs: VFIOSysfs) throws {
        let deviceDir = URL(fileURLWithPath: paths.devicesRoot, isDirectory: true)
            .appendingPathComponent(address, isDirectory: true)
        guard sysfs.fileExists(deviceDir.path) else { return }
        guard sysfs.currentDriver(address) == "vfio-pci" else { return }

        try requireSysfsNode(
            paths.vfioPciDriver,
            operation: "unbind",
            cause: "the vfio-pci kernel module is not loaded",
            sysfs: sysfs,
        )
        let unbind = URL(fileURLWithPath: paths.vfioPciDriver, isDirectory: true)
            .appendingPathComponent("unbind")
            .path
        try requireSysfsNode(
            unbind,
            operation: "unbind",
            cause: "the vfio-pci unbind node is missing from sysfs",
            sysfs: sysfs,
        )
        try write("\(address)\n", to: unbind, sysfs: sysfs)

        let override = deviceDir.appendingPathComponent("driver_override").path
        try requireSysfsNode(
            override,
            operation: "unbind",
            cause: "this kernel does not support driver_override",
            sysfs: sysfs,
        )
        try write("\n", to: override, sysfs: sysfs)
        try requireSysfsNode(
            paths.driversProbe,
            operation: "unbind",
            cause: "the PCI drivers_probe node is missing from sysfs",
            sysfs: sysfs,
        )
        try write("\(address)\n", to: paths.driversProbe, sysfs: sysfs)

        if sysfs.currentDriver(address) == "vfio-pci" {
            throw BarkVisorError.forbidden(
                "GPU \(address) is still bound to vfio-pci after unbind",
            )
        }
    }

    private static func requireSysfsNode(
        _ path: String,
        operation: String,
        cause: String,
        sysfs: VFIOSysfs,
    ) throws {
        guard sysfs.fileExists(path) else {
            throw BarkVisorError.forbidden(
                "vfio-pci \(operation) failed: \(path) does not exist; \(cause)",
            )
        }
    }

    private static func write(_ text: String, to path: String, sysfs: VFIOSysfs) throws {
        do {
            try sysfs.write(text, path)
        } catch {
            throw BarkVisorError.forbidden(
                "vfio-pci sysfs write failed at \(path): \(error.localizedDescription)",
            )
        }
    }
}
