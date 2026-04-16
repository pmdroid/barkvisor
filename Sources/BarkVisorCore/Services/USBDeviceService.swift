import Foundation

public struct HostUSBDevice: Codable {
    public let vendorId: String
    public let productId: String
    public let name: String
    public let manufacturer: String?
    public let serialNumber: String?

    public init(
        vendorId: String, productId: String, name: String, manufacturer: String?, serialNumber: String?,
    ) {
        self.vendorId = vendorId
        self.productId = productId
        self.name = name
        self.manufacturer = manufacturer
        self.serialNumber = serialNumber
    }
}

public enum USBDeviceService {
    /// List non-storage USB devices connected to the host.
    /// Uses `ioreg` (IOKit registry) which is reliable on Apple Silicon,
    /// unlike `system_profiler SPUSBDataType` which can return empty results.
    /// USB mass storage devices are excluded — they require macOS to release
    /// the device first and are unreliable for passthrough on macOS.
    public static func listDevices() throws -> [HostUSBDevice] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        proc.arguments = ["-p", "IOUSB", "-c", "IOUSBHostDevice", "-r", "-a"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return [] }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            return []
        }

        // Recursively collect all entries from the tree structure
        // USB devices can be nested under hubs, so we need to traverse IORegistryEntryChildren
        var allEntries: [[String: Any]] = []
        collectUSBHostDevices(from: plist, into: &allEntries)

        // Collect product names of USB storage devices so we can exclude them
        let storageNames = findUSBStorageProductNames()

        var devices: [HostUSBDevice] = []
        for entry in allEntries {
            guard let vendorInt = entry["idVendor"] as? Int,
                  let productInt = entry["idProduct"] as? Int
            else {
                continue
            }

            // Skip Apple internal peripherals (vendor 0x05ac) but allow
            // iPhones, iPads, and iPods which use the same vendor ID.
            // Apple mobile device product IDs fall in the 0x12a0–0x12ff range.
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

            // Skip USB mass storage devices — they need macOS to release them
            // and cause STALL errors in the guest firmware
            if storageNames.contains(name) { continue }

            let vid = String(format: "0x%04x", vendorInt)
            let pid = String(format: "0x%04x", productInt)

            devices.append(
                HostUSBDevice(
                    vendorId: vid, productId: pid,
                    name: name, manufacturer: manufacturer, serialNumber: serial,
                ),
            )
        }

        return devices
    }

    /// Find product names of USB devices that are registered as external physical disks.
    private static func findUSBStorageProductNames() -> Set<String> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["list", "-plist", "external", "physical"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any],
            let disks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else {
            return []
        }

        var names = Set<String>()
        for disk in disks {
            guard let deviceId = disk["DeviceIdentifier"] as? String else { continue }

            let infoProc = Process()
            infoProc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            infoProc.arguments = ["info", "-plist", deviceId]
            let infoPipe = Pipe()
            infoProc.standardOutput = infoPipe
            infoProc.standardError = FileHandle.nullDevice
            guard (try? infoProc.run()) != nil else { continue }
            infoProc.waitUntilExit()
            guard infoProc.terminationStatus == 0 else { continue }

            let infoData = infoPipe.fileHandleForReading.readDataToEndOfFile()
            if let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil)
                as? [String: Any],
                let mediaName = info["MediaName"] as? String, !mediaName.isEmpty {
                names.insert(mediaName)
            }
        }
        return names
    }

    /// Recursively collect all IOUSBHostDevice entries from the ioreg tree.
    /// Devices are nested under parent hubs in IORegistryEntryChildren arrays.
    private static func collectUSBHostDevices(from node: Any, into collection: inout [[String: Any]]) {
        if let entry = node as? [String: Any] {
            // If this entry has idVendor and idProduct, it's a USB device
            if entry["idVendor"] is Int, entry["idProduct"] is Int {
                collection.append(entry)
            }
            // Recursively check children
            if let children = entry["IORegistryEntryChildren"] as? [Any] {
                for child in children {
                    collectUSBHostDevices(from: child, into: &collection)
                }
            }
        } else if let array = node as? [Any] {
            // Handle case where root is an array
            for element in array {
                collectUSBHostDevices(from: element, into: &collection)
            }
        }
    }
}
