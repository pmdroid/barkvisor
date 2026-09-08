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
        let key = cacheKey(for: binary)
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

    static func cacheKey(for binary: URL) -> String {
        var key = binaryIdentityKey(for: binary)
        for dir in moduleDirectories(for: binary) {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .sorted()
                .compactMap { name -> String? in
                    let path = URL(fileURLWithPath: dir).appendingPathComponent(name)
                    guard name.hasSuffix(".so"),
                          let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
                    else { return nil }
                    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    return "\(name):\(mtime)"
                } ?? []
            key += "|\(dir)=\(entries.joined(separator: ","))"
        }
        return key
    }

    static func moduleDirectories(for binary: URL) -> [String] {
        let binDir = binary.deletingLastPathComponent().path
        return [
            "/usr/lib/qemu",
            "/usr/local/lib/qemu",
            "/opt/homebrew/lib/qemu",
            URL(fileURLWithPath: binDir).deletingLastPathComponent()
                .appendingPathComponent("lib/qemu").path,
        ]
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
