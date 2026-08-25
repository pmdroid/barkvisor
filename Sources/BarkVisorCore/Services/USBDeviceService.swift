import Foundation

public struct HostUSBDevice: Codable, Equatable, Sendable {
    public let id: String
    public let vendorId: String
    public let productId: String
    public let name: String
    public let manufacturer: String?
    public let serialNumber: String?
    public let bus: Int?
    public let address: Int?
    public let idUnstable: Bool
    public let attachable: Bool
    public let excludedReason: String?

    public var productName: String {
        name
    }

    public init(
        vendorId: String,
        productId: String,
        name: String,
        manufacturer: String?,
        serialNumber: String?,
        bus: Int? = nil,
        address: Int? = nil,
        attachable: Bool = true,
        excludedReason: String? = nil,
    ) {
        let ref = USBDeviceIdentity.make(
            vendorId: vendorId,
            productId: productId,
            serial: serialNumber,
            bus: bus,
            address: address,
        )
        self.id = ref.id
        self.vendorId = ref.vendorId.isEmpty ? USBDeviceIdentity.normalizeHexId(vendorId) : ref.vendorId
        self.productId = ref.productId.isEmpty
            ? USBDeviceIdentity.normalizeHexId(productId) : ref.productId
        self.name = name
        self.manufacturer = manufacturer
        self.serialNumber = USBDeviceIdentity.normalizedSerial(serialNumber)
        self.bus = bus
        self.address = address
        self.idUnstable = ref.unstable
        self.attachable = attachable
        self.excludedReason = excludedReason
    }
}

public enum USBDeviceService {
    /// List USB devices connected to the host, including excluded mass-storage entries.
    /// - macOS: `ioreg` (IOKit registry)
    /// - Linux: sysfs (`/sys/bus/usb/devices`), falling back to `lsusb`
    public static func listDevices() throws -> [HostUSBDevice] {
        #if os(macOS)
            try listDevicesMacOS()
        #elseif os(Linux)
            try listDevicesLinux()
        #else
            []
        #endif
    }

    /// IOKit "USB Address" is the device address used by QEMU `hostaddr`.
    /// `PortNum` is the hub port index and must not be used as a fallback.
    public static func parseIORegistryUSBAddress(_ entry: [String: Any]) -> Int? {
        intFromPlist(entry["USB Address"])
    }

    /// USB controller bus used by QEMU `hostbus` / libusb.
    /// Real `IOUSBHostDevice` entries typically omit "Bus Number"; the high
    /// byte of `locationID` is the same bus encoded in `@BBAAAA` device names.
    public static func parseIORegistryUSBBus(_ entry: [String: Any]) -> Int? {
        if let bus = intFromPlist(entry["Bus Number"]) {
            return bus
        }
        guard let locationID = uint32FromPlist(entry["locationID"]) else {
            return nil
        }
        return Int(locationID >> 24)
    }

    private static func intFromPlist(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    /// IOKit `locationID` is a 32-bit topology word. Read it unsigned so bus
    /// values ≥ 128 (high bit set) survive NSNumber / signed Int conversion.
    private static func uint32FromPlist(_ raw: Any?) -> UInt32? {
        if let value = raw as? UInt32 { return value }
        if let value = raw as? UInt, value <= UInt32.max { return UInt32(value) }
        if let value = raw as? Int, (0 ... Int(UInt32.max)).contains(value) {
            return UInt32(value)
        }
        if let value = raw as? NSNumber { return value.uint32Value }
        return nil
    }

    /// Parse `lsusb` lines: `Bus 001 Device 002: ID abcd:1234 Vendor Product`
    /// Public for unit tests on all platforms.
    public static func parseLsusbLine(_ line: String) -> HostUSBDevice? {
        guard let idRange = line.range(
            of: #"ID\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})"#,
            options: .regularExpression,
        ) else {
            return nil
        }
        let idToken = String(line[idRange])
        let hexPart = idToken.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? ""
        let vp = hexPart.split(separator: ":")
        guard vp.count == 2 else { return nil }
        let vid = "0x\(vp[0].lowercased())"
        let pid = "0x\(vp[1].lowercased())"

        var bus: Int?
        var address: Int?
        if let busRange = line.range(of: #"Bus\s+(\d+)\s+Device\s+(\d+)"#, options: .regularExpression) {
            let nums = String(line[busRange]).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 2 {
                bus = nums[0]
                address = nums[1]
            }
        }

        var name = ""
        if let afterID = line.range(
            of: #"ID\s+[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\s*"#,
            options: .regularExpression,
        ) {
            name = String(line[afterID.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name.isEmpty { name = "USB Device" }
        if name.localizedCaseInsensitiveContains("root hub") { return nil }

        return HostUSBDevice(
            vendorId: vid,
            productId: pid,
            name: name,
            manufacturer: nil,
            serialNumber: nil,
            bus: bus,
            address: address,
        )
    }

    public static func sysfsDevice(bus: Int, address: Int, root: URL) -> HostUSBDevice? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        for name in names.sorted() {
            if name.hasPrefix("usb") || name.contains(":") { continue }
            let dir = root.appendingPathComponent(name)
            guard let dev = parseSysfsDevice(at: dir),
                  dev.bus == bus, dev.address == address
            else { continue }
            return dev
        }
        return nil
    }

    public static func withSysfsIdentity(_ device: HostUSBDevice, root: URL) -> HostUSBDevice {
        guard let bus = device.bus, let address = device.address else { return device }
        return sysfsDevice(bus: bus, address: address, root: root) ?? device
    }

    /// Enumerate a sysfs USB tree (`/sys/bus/usb/devices` layout). Public for tests.
    public static func listSysfsDevices(root: URL) -> [HostUSBDevice] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var devices: [HostUSBDevice] = []
        var seen = Set<String>()
        for name in names.sorted() {
            // Device nodes are `1-1` / `2-3.1`. Skip root hubs (`usb1`) and interfaces (`1-1:1.0`).
            if name.hasPrefix("usb") || name.contains(":") { continue }
            let dir = root.appendingPathComponent(name)
            guard let dev = parseSysfsDevice(at: dir) else { continue }
            if seen.insert(dev.id).inserted {
                devices.append(dev)
            }
        }
        return devices
    }

    /// Parse one sysfs device directory. Public for tests.
    public static func parseSysfsDevice(at directory: URL) -> HostUSBDevice? {
        let fm = FileManager.default
        func read(_ name: String) -> String? {
            let path = directory.appendingPathComponent(name).path
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let vendorHex = read("idVendor"), let productHex = read("idProduct") else {
            return nil
        }
        if read("bDeviceClass") == "09" { return nil }

        let bus = read("busnum").flatMap(Int.init)
        let address = read("devnum").flatMap(Int.init)
        let serial = read("serial")
        let product = read("product") ?? "USB Device"
        let manufacturer = read("manufacturer")
        let vid = USBDeviceIdentity.normalizeHexId(vendorHex)
        let pid = USBDeviceIdentity.normalizeHexId(productHex)

        let massStorage = isSysfsMassStorage(at: directory, fileManager: fm)
        return HostUSBDevice(
            vendorId: vid,
            productId: pid,
            name: product,
            manufacturer: manufacturer,
            serialNumber: serial,
            bus: bus,
            address: address,
            attachable: !massStorage,
            excludedReason: massStorage ? USBDeviceIdentity.massStorageExclusionReason : nil,
        )
    }

    private static func isSysfsMassStorage(at directory: URL, fileManager fm: FileManager) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
        for name in names where name.contains(":") {
            let classPath = directory.appendingPathComponent(name).appendingPathComponent("bInterfaceClass")
            if let raw = try? String(contentsOfFile: classPath.path, encoding: .utf8),
               raw.trimmingCharacters(in: .whitespacesAndNewlines) == "08" {
                return true
            }
        }
        return false
    }

    public static func listLinuxDevices(sysfsRoot: URL, lsusbLines: [String]) -> [HostUSBDevice] {
        let fromSys = listSysfsDevices(root: sysfsRoot)
        if !fromSys.isEmpty { return fromSys }
        return listedFromLsusb(lsusbLines, sysfsRoot: sysfsRoot)
    }

    private static func listedFromLsusb(_ lines: [String], sysfsRoot: URL) -> [HostUSBDevice] {
        var devices: [HostUSBDevice] = []
        var seen = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let parsed = parseLsusbLine(trimmed) else { continue }
            let dev = withSysfsIdentity(parsed, root: sysfsRoot)
            if seen.insert(dev.id).inserted {
                devices.append(dev)
            }
        }
        return devices
    }

    #if os(Linux)
        private static func listDevicesLinux() throws -> [HostUSBDevice] {
            let sysRoot = URL(fileURLWithPath: "/sys/bus/usb/devices")
            let fromSys = listSysfsDevices(root: sysRoot)
            if !fromSys.isEmpty { return fromSys }
            return listedFromLsusb(lsusbStdoutLines(), sysfsRoot: sysRoot)
        }

        private static func lsusbStdoutLines() -> [String] {
            let lsusbPaths = ["/usr/bin/lsusb", "/bin/lsusb"]
            guard let exe = lsusbPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else {
                return []
            }

            let result = (try? PlatformProcess.run(path: exe, arguments: [], timeout: 15)) ?? .init(
                exitCode: -1, stdout: Data(), stderr: Data(),
            )
            guard result.succeeded else { return [] }
            let text = result.stdoutString
            guard !text.isEmpty else { return [] }
            return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    #endif

    #if os(macOS)
        /// Uses `ioreg` which is reliable on Apple Silicon, unlike
        /// `system_profiler SPUSBDataType` which can return empty results.
        /// USB mass storage devices are listed as not attachable.
        private static func listDevicesMacOS() throws -> [HostUSBDevice] {
            let result = (try? PlatformProcess.run(
                path: "/usr/sbin/ioreg",
                arguments: ["-p", "IOUSB", "-c", "IOUSBHostDevice", "-r", "-a"],
                timeout: 15,
            )) ?? .init(exitCode: -1, stdout: Data(), stderr: Data())
            guard result.succeeded, !result.stdout.isEmpty else { return [] }

            guard let plist = try? PropertyListSerialization.propertyList(
                from: result.stdout, format: nil,
            )
            else {
                return []
            }

            var allEntries: [[String: Any]] = []
            collectUSBHostDevices(from: plist, into: &allEntries)

            let storageNames = findUSBStorageProductNames()

            var devices: [HostUSBDevice] = []
            var seen = Set<String>()
            for entry in allEntries {
                guard let vendorInt = entry["idVendor"] as? Int,
                      let productInt = entry["idProduct"] as? Int
                else {
                    continue
                }

                // Skip Apple internal peripherals (vendor 0x05ac) but allow
                // iPhones, iPads, and iPods which use the same vendor ID.
                if vendorInt == 0x05AC {
                    let isMobileDevice = (0x12A0 ... 0x12FF).contains(productInt)
                    if !isMobileDevice { continue }
                }

                let name =
                    entry["USB Product Name"] as? String
                        ?? entry["IORegistryEntryName"] as? String
                        ?? "Unknown USB Device"
                let manufacturer = entry["USB Vendor Name"] as? String
                let serial = entry["USB Serial Number"] as? String
                let bus = parseIORegistryUSBBus(entry)
                let address = parseIORegistryUSBAddress(entry)

                let vid = String(format: "0x%04x", vendorInt)
                let pid = String(format: "0x%04x", productInt)
                let isStorage = storageNames.contains(name)

                let device = HostUSBDevice(
                    vendorId: vid,
                    productId: pid,
                    name: name,
                    manufacturer: manufacturer,
                    serialNumber: serial,
                    bus: bus,
                    address: address,
                    attachable: !isStorage,
                    excludedReason: isStorage ? USBDeviceIdentity.massStorageExclusionReason : nil,
                )
                if seen.insert(device.id).inserted {
                    devices.append(device)
                }
            }

            return devices
        }

        /// Find product names of USB devices that are registered as external physical disks.
        private static func findUSBStorageProductNames() -> Set<String> {
            let list = (try? PlatformProcess.run(
                path: "/usr/sbin/diskutil",
                arguments: ["list", "-plist", "external", "physical"],
                timeout: 15,
            )) ?? .init(exitCode: -1, stdout: Data(), stderr: Data())
            guard list.succeeded else { return [] }

            guard let plist = try? PropertyListSerialization.propertyList(
                from: list.stdout, format: nil,
            ) as? [String: Any],
                let disks = plist["AllDisksAndPartitions"] as? [[String: Any]]
            else {
                return []
            }

            var names = Set<String>()
            for disk in disks {
                guard let deviceId = disk["DeviceIdentifier"] as? String else { continue }

                let info = (try? PlatformProcess.run(
                    path: "/usr/sbin/diskutil",
                    arguments: ["info", "-plist", deviceId],
                    timeout: 10,
                )) ?? .init(exitCode: -1, stdout: Data(), stderr: Data())
                guard info.succeeded else { continue }

                if let infoPlist = try? PropertyListSerialization.propertyList(
                    from: info.stdout, format: nil,
                ) as? [String: Any],
                    let mediaName = infoPlist["MediaName"] as? String, !mediaName.isEmpty {
                    names.insert(mediaName)
                }
            }
            return names
        }

        /// Recursively collect all IOUSBHostDevice entries from the ioreg tree.
        /// Devices are nested under parent hubs in IORegistryEntryChildren arrays.
        private static func collectUSBHostDevices(from node: Any, into collection: inout [[String: Any]]) {
            if let entry = node as? [String: Any] {
                if entry["idVendor"] is Int, entry["idProduct"] is Int {
                    collection.append(entry)
                }
                if let children = entry["IORegistryEntryChildren"] as? [Any] {
                    for child in children {
                        collectUSBHostDevices(from: child, into: &collection)
                    }
                }
            } else if let array = node as? [Any] {
                for element in array {
                    collectUSBHostDevices(from: element, into: &collection)
                }
            }
        }
    #endif
}
