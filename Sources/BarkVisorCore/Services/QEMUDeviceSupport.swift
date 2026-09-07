import Foundation

public enum QEMUDeviceSupport {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Set<String>?] = [:]

    static let probeArguments = ["-device", "help"]

    public static let requiredLaunchDevices: Set<String> = [
        "qemu-xhci", "ramfb", "virtio-gpu-pci", "usb-kbd", "usb-tablet",
        "virtio-net-pci", "virtio-serial-pci", "virtio-blk-pci",
    ]

    public static let requiredWindowsDevices: Set<String> = ["nvme", "usb-storage"]

    public static func supportedDeviceNames(binary: URL) -> Set<String>? {
        let key = binaryIdentityKey(for: binary)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let probed = probe(binary: binary)
        lock.lock()
        cache[key] = probed
        lock.unlock()
        return probed
    }

    static func binaryIdentityKey(for binary: URL) -> String {
        let path = binary.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(path)|\(mtime)|\(size)"
    }

    private static func probe(binary: URL) -> Set<String>? {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        guard let result = try? PlatformProcess.run(
            executable: binary,
            arguments: probeArguments,
            timeout: 8,
        ) else { return nil }
        let text = result.stdoutString + "\n" + result.stderrString
        return parseDeviceNames(text)
    }

    static func parseDeviceNames(_ text: String) -> Set<String>? {
        var names = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let start = line.range(of: "name \"") else { continue }
            let rest = line[start.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                names.insert(String(rest[..<end]))
            }
        }
        guard !names.isEmpty else { return nil }
        return names
    }
}
