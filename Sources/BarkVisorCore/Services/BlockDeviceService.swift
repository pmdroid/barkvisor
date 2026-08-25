import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct HostBlockDevice: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let sizeBytes: Int64
    public let model: String?
    public let attachable: Bool
    public let excludedReason: String?

    public init(
        path: String,
        name: String,
        sizeBytes: Int64,
        model: String?,
        attachable: Bool,
        excludedReason: String?,
    ) {
        self.path = path
        self.name = name
        self.sizeBytes = sizeBytes
        self.model = model
        self.attachable = attachable
        self.excludedReason = excludedReason
    }
}

public enum BlockDeviceService {
    public static let sysBlockRoot = URL(fileURLWithPath: "/sys/block")

    public static func listDevices(
        fileManager: FileManager = .default,
    ) -> [HostBlockDevice] {
        #if os(Linux)
            let mounts = (try? String(contentsOfFile: "/proc/mounts", encoding: .utf8)) ?? ""
            let swaps = (try? String(contentsOfFile: "/proc/swaps", encoding: .utf8)) ?? ""
            return listSysfsDevices(
                root: sysBlockRoot,
                mounts: mounts,
                swaps: swaps,
                fileManager: fileManager,
            )
        #else
            _ = fileManager
            return []
        #endif
    }

    public static func listSysfsDevices(
        root: URL,
        mounts: String = "",
        swaps: String = "",
        fileManager: FileManager = .default,
    ) -> [HostBlockDevice] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var devices: [HostBlockDevice] = []
        for name in names.sorted() {
            if shouldSkip(name) { continue }
            let dir = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
            else {
                continue
            }
            let sizeBytes = sysfsSizeBytes(at: dir, fileManager: fileManager) ?? 0
            let model = sysfsText(at: dir.appendingPathComponent("device/model"), fileManager: fileManager)
            let path = "/dev/\(name)"
            let reason = hostUseReason(path: path, mounts: mounts, swaps: swaps)
            devices.append(
                HostBlockDevice(
                    path: path,
                    name: name,
                    sizeBytes: sizeBytes,
                    model: model,
                    attachable: reason == nil,
                    excludedReason: reason,
                ),
            )
        }
        return devices
    }

    public static func readWriteDeniedCopy(path: String) -> String {
        "Cannot open '\(path)' for read/write. The BarkVisor user needs the disk group (or a udev ACL)."
    }

    public static func readWriteDeniedReason(
        path: String,
        openReadWrite: ((String) throws -> Void)? = nil,
    ) -> String? {
        do {
            if let openReadWrite {
                try openReadWrite(path)
            } else {
                try openPathReadWrite(path)
            }
            return nil
        } catch {
            if isPermissionDenied(error) {
                return readWriteDeniedCopy(path: path)
            }
            return "Cannot open '\(path)' for read/write."
        }
    }

    public static func requireReadWrite(
        path: String,
        openReadWrite: ((String) throws -> Void)? = nil,
    ) throws {
        if let reason = readWriteDeniedReason(path: path, openReadWrite: openReadWrite) {
            throw BarkVisorError.badRequest(reason)
        }
    }

    public static func requireHostDeviceReadWrite(
        paths: [String],
        openReadWrite: ((String) throws -> Void)? = nil,
    ) throws {
        for path in paths where DiskSettings.isHostDevicePath(path) {
            try requireReadWrite(path: path, openReadWrite: openReadWrite)
        }
    }

    /// Why this `/dev` node must not be passed through: mounted, swap, or the host root disk.
    public static func hostUseReason(path: String, mounts: String, swaps: String = "") -> String? {
        let node = URL(fileURLWithPath: path).lastPathComponent
        guard !node.isEmpty else { return nil }
        let whole = wholeDiskName(from: node)
        if let root = rootDiskName(from: mounts), whole == root {
            return "Host root disk"
        }
        let used = usedDeviceNames(from: mounts).union(usedDeviceNames(from: swaps))
        if used.contains(node) {
            return "Device is mounted on the host"
        }
        if used.contains(where: { wholeDiskName(from: $0) == whole }) {
            return "Device is in use by the host"
        }
        return nil
    }

    public static func usedDeviceNames(from text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            for token in line.split(separator: " ", omittingEmptySubsequences: true) {
                let source = String(token)
                guard source.hasPrefix("/dev/") else { continue }
                names.insert(String(source.dropFirst(5)))
            }
        }
        return names
    }

    public static func isBlockDevice(
        _ path: String,
        fileManager: FileManager = .default,
    ) -> Bool {
        guard let type = try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeBlockSpecial
    }

    public static func sizeBytes(
        _ path: String,
        fileManager: FileManager = .default,
    ) -> Int64? {
        if let size = try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64, size > 0 {
            return size
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let sys = sysBlockRoot.appendingPathComponent(name).appendingPathComponent("size")
        return sysfsSectorsToBytes(sysfsText(at: sys, fileManager: fileManager))
    }

    public static func shouldSkip(_ name: String) -> Bool {
        let skipped = ["loop", "ram", "zram", "fd", "sr", "nbd", "dm-", "md"]
        return skipped.contains { name == $0 || name.hasPrefix($0) }
    }

    public static func rootDiskName(from mounts: String) -> String? {
        for line in mounts.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            guard parts[1] == "/" else { continue }
            let source = String(parts[0])
            guard source.hasPrefix("/dev/") else { continue }
            return wholeDiskName(from: String(source.dropFirst(5)))
        }
        return nil
    }

    public static func wholeDiskName(from node: String) -> String {
        if let range = node.range(of: #"p\d+$"#, options: .regularExpression) {
            return String(node[..<range.lowerBound])
        }
        if let range = node.range(of: #"\d+$"#, options: .regularExpression),
           node.range(of: #"nvme|mmcblk"#, options: .regularExpression) == nil {
            return String(node[..<range.lowerBound])
        }
        return node
    }

    private static func sysfsSizeBytes(at dir: URL, fileManager: FileManager) -> Int64? {
        sysfsSectorsToBytes(
            sysfsText(at: dir.appendingPathComponent("size"), fileManager: fileManager),
        )
    }

    private static func sysfsSectorsToBytes(_ raw: String?) -> Int64? {
        guard let raw, let sectors = Int64(raw), sectors > 0 else { return nil }
        return sectors * 512
    }

    private static func sysfsText(at url: URL, fileManager: FileManager) -> String? {
        _ = fileManager
        guard let raw = try? String(contentsOfFile: url.path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    package static func openPathReadWrite(_ path: String) throws {
        #if canImport(Darwin)
            let fd = path.withCString { Darwin.open($0, O_RDWR) }
        #elseif canImport(Glibc)
            let fd = path.withCString { Glibc.open($0, O_RDWR) }
        #else
            let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
            try handle.close()
            return
        #endif
        if fd < 0 {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        #if canImport(Darwin)
            _ = Darwin.close(fd)
        #elseif canImport(Glibc)
            _ = Glibc.close(fd)
        #endif
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return ns.code == Int(EACCES) || ns.code == Int(EPERM)
        }
        if ns.domain == NSCocoaErrorDomain {
            return ns.code == NSFileReadNoPermissionError
                || ns.code == NSFileWriteNoPermissionError
        }
        return false
    }
}
