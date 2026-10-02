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
            let usage = liveUsage(fileManager: fileManager)
            return listSysfsDevices(
                root: sysBlockRoot,
                mounts: usage.mounts,
                swaps: usage.swaps,
                zpoolStatus: usage.zpoolStatus,
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
        zpoolStatus: String? = "",
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
            let reason = hostUseReason(
                path: path, mounts: mounts, swaps: swaps, root: root,
                zpoolStatus: zpoolStatus, fileManager: fileManager,
            )
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
        hostUse: ((String) -> String?)? = nil,
    ) throws {
        let hostPaths = paths.filter(DiskSettings.isHostDevicePath)
        guard !hostPaths.isEmpty else { return }
        let usage = hostUse == nil ? liveUsage() : nil
        for path in hostPaths {
            let reason: String? = if let hostUse {
                hostUse(path)
            } else if let usage {
                hostUseReason(path: path, mounts: usage.mounts, swaps: usage.swaps, zpoolStatus: usage.zpoolStatus)
            } else {
                "Cannot verify host storage use"
            }
            if let reason { throw BarkVisorError.badRequest(reason) }
            try requireReadWrite(path: path, openReadWrite: openReadWrite)
        }
    }

    /// Why this `/dev` node must not be passed through: mounted, swap, or the host root disk.
    public static func hostUseReason(
        path: String,
        mounts: String,
        swaps: String = "",
        root: URL = sysBlockRoot,
        zpoolStatus: String? = "",
        fileManager: FileManager = .default,
    ) -> String? {
        let node = URL(fileURLWithPath: path).resolvingSymlinksInPath().lastPathComponent
        guard !node.isEmpty else { return nil }
        let whole = wholeDiskName(from: node)
        if let root = rootDiskName(from: mounts), whole == root {
            return "Host root disk"
        }
        guard let zpoolStatus else { return "Cannot verify host storage use" }
        let used = usedDeviceNames(from: mounts).union(usedDeviceNames(from: swaps))
            .union(usedDeviceNames(from: zpoolStatus))
        if used.contains(node) {
            return "Device is mounted on the host"
        }
        if used.contains(where: { wholeDiskName(from: $0) == whole }) {
            return "Device is in use by the host"
        }
        do {
            let dependencies = try deviceDependencies(used, root: root, fileManager: fileManager)
            if dependencies.contains(where: { wholeDiskName(from: $0) == whole }) {
                return "Device is in use by the host"
            }
            let dir = sysfsDirectory(node: whole, root: root)
            if fileManager.fileExists(atPath: dir.path) {
                var members = [dir]
                let children = try fileManager.contentsOfDirectory(atPath: dir.path)
                members += children.filter { $0 != whole && wholeDiskName(from: $0) == whole }
                    .map { dir.appendingPathComponent($0) }
                for member in members {
                    let holders = member.appendingPathComponent("holders")
                    if fileManager.fileExists(atPath: holders.path),
                       try !fileManager.contentsOfDirectory(atPath: holders.path).isEmpty {
                        return "Device is in use by the host"
                    }
                }
            }
        } catch {
            return "Cannot verify host storage use"
        }
        return nil
    }

    public static func liveHostUseReason(
        path: String,
        mounts: String? = nil,
        swaps: String? = nil,
        fileManager: FileManager = .default,
    ) -> String? {
        let usage = liveUsage(mounts: mounts, swaps: swaps, fileManager: fileManager)
        return hostUseReason(
            path: path, mounts: usage.mounts, swaps: usage.swaps,
            zpoolStatus: usage.zpoolStatus, fileManager: fileManager,
        )
    }

    private static func liveUsage(
        mounts: String? = nil,
        swaps: String? = nil,
        fileManager: FileManager = .default,
    ) -> (mounts: String, swaps: String, zpoolStatus: String?) {
        #if os(Linux)
            guard let mounts = mounts ?? (try? String(contentsOfFile: "/proc/mounts", encoding: .utf8)),
                  let swaps = swaps ?? (try? String(contentsOfFile: "/proc/swaps", encoding: .utf8)),
                  (try? fileManager.contentsOfDirectory(atPath: sysBlockRoot.path)) != nil else {
                return ("", "", nil)
            }
            return (mounts, swaps, readZpoolStatus(mounts: mounts, fileManager: fileManager))
        #else
            return (mounts ?? "", swaps ?? "", "")
        #endif
    }

    package static func readZpoolStatus(
        mounts: String,
        executablePath: String? = nil,
        zfsLoaded: Bool? = nil,
        fileManager: FileManager = .default,
        invoke: ((String, [String]) throws -> CommandResult)? = nil,
    ) -> String? {
        let active = zfsLoaded ?? fileManager.fileExists(atPath: "/sys/module/zfs")
        let mounted = mounts.split(separator: "\n").contains { $0.split(whereSeparator: \.isWhitespace).dropFirst(2).first == "zfs" }
        guard active || mounted else { return "" }
        let path = executablePath ?? ["/usr/sbin/zpool", "/sbin/zpool", "/usr/bin/zpool", "/bin/zpool"]
            .first { fileManager.isExecutableFile(atPath: $0) }
        guard let path else { return nil }
        let run = invoke ?? { try PlatformProcess.run(path: $0, arguments: $1, timeout: 2) }
        guard let result = try? run(path, ["status", "-LP"]), result.succeeded else { return nil }
        let output = result.stdoutString
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return !mounted && result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines) == "no pools available" ? "" : nil
        }
        guard output.split(whereSeparator: \.isWhitespace).contains("pool:") else { return nil }
        return output
    }

    private static func sysfsDirectory(node: String, root: URL) -> URL {
        let whole = wholeDiskName(from: node)
        let dir = root.appendingPathComponent(whole)
        return node == whole ? dir : dir.appendingPathComponent(node)
    }

    private static func deviceDependencies(
        _ names: Set<String>,
        root: URL,
        fileManager: FileManager,
    ) throws -> Set<String> {
        var seen = Set<String>()
        var pending = Array(names)
        while let node = pending.popLast() {
            guard seen.insert(node).inserted else { continue }
            let dir = sysfsDirectory(node: node, root: root)
            guard fileManager.fileExists(atPath: dir.path) else {
                let mapper = try fileManager.contentsOfDirectory(atPath: root.path).first {
                    node.hasPrefix("mapper/") && $0.hasPrefix("dm-")
                        && sysfsText(at: root.appendingPathComponent("\($0)/dm/name"), fileManager: fileManager) == URL(fileURLWithPath: node)
                        .lastPathComponent
                }
                guard let mapper else { throw BarkVisorError.badRequest("Cannot verify host storage use") }
                pending.append(mapper)
                continue
            }
            let whole = wholeDiskName(from: node)
            if whole != node { pending.append(whole) }
            let backingDevices = dir.appendingPathComponent("slaves")
            if whole == node {
                pending += try fileManager.contentsOfDirectory(atPath: backingDevices.path)
            }
        }
        return seen
    }

    public static func usedDeviceNames(from text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            for token in line.split(whereSeparator: \.isWhitespace) {
                let source = String(token)
                guard source.hasPrefix("/dev/") else { continue }
                names.insert(String(URL(fileURLWithPath: source).resolvingSymlinksInPath().path.dropFirst(5)))
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
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            guard parts[1] == "/" else { continue }
            let source = String(parts[0])
            guard source.hasPrefix("/dev/") else { continue }
            return wholeDiskName(from: URL(fileURLWithPath: source).resolvingSymlinksInPath().lastPathComponent)
        }
        return nil
    }

    public static func wholeDiskName(from node: String) -> String {
        if let range = node.range(of: #"(?<=\d)p\d+$"#, options: .regularExpression) {
            return String(node[..<range.lowerBound])
        }
        if node.hasPrefix("dm-") || node.hasPrefix("md") { return node }
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
            if fd < 0 {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            _ = Darwin.close(fd)
        #elseif canImport(Glibc)
            let fd = path.withCString { Glibc.open($0, O_RDWR) }
            if fd < 0 {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            _ = Glibc.close(fd)
        #else
            let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
            try handle.close()
        #endif
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return ns.code == Int(POSIXErrorCode.EACCES.rawValue)
                || ns.code == Int(POSIXErrorCode.EPERM.rawValue)
        }
        if ns.domain == NSCocoaErrorDomain {
            return ns.code == NSFileReadNoPermissionError
                || ns.code == NSFileWriteNoPermissionError
        }
        return false
    }
}
