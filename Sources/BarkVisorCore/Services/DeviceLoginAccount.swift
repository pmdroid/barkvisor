import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum DeviceLoginAccount: Sendable {
    public enum PlatformKind: String, Sendable {
        case macOS
        case linux
    }

    public struct Record: Equatable, Sendable {
        public let name: String
        public let uid: UInt32
        public let gid: UInt32
        public let home: String
        public let shell: String

        public init(name: String, uid: UInt32, gid: UInt32, home: String, shell: String) {
            self.name = name
            self.uid = uid
            self.gid = gid
            self.home = home
            self.shell = shell
        }
    }

    public struct Credentials: Sendable {
        public let uid: UInt32
        public let gid: UInt32
        public let groups: [UInt32]

        public init(uid: UInt32, gid: UInt32, groups: [UInt32]) {
            self.uid = uid
            self.gid = gid
            self.groups = groups
        }
    }

    private static let lock = NSLock()

    public static var currentPlatform: PlatformKind {
        #if os(macOS)
            .macOS
        #else
            .linux
        #endif
    }

    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 32 else { return false }
        guard let first = name.unicodeScalars.first else { return false }
        let letters = CharacterSet.letters.union(CharacterSet.decimalDigits)
        guard letters.contains(first) else { return false }
        let allowed = letters.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func isLoginShell(_ shell: String) -> Bool {
        let trimmed = shell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let base = (trimmed as NSString).lastPathComponent.lowercased()
        return base != "nologin" && base != "false" && base != "true"
    }

    public static func systemUIDFloor(platform: PlatformKind) -> UInt32 {
        switch platform {
        case .macOS: return 500
        case .linux: return 1000
        }
    }

    public static func isOffered(
        name: String,
        uid: UInt32,
        shell: String,
        euid: UInt32,
        platform: PlatformKind,
    ) -> Bool {
        guard isSafeName(name) else { return false }
        if euid != 0 {
            return uid == euid
        }
        if uid == 0 { return false }
        if uid < systemUIDFloor(platform: platform) { return false }
        if name.hasPrefix("_") { return false }
        if name == "nobody" || name == "nfsnobody" { return false }
        return isLoginShell(shell)
    }

    public static func isSpawnAllowed(
        name: String,
        uid: UInt32,
        shell: String,
        euid: UInt32,
        platform: PlatformKind,
    ) -> Bool {
        guard uid != 0 else { return false }
        if euid != 0 {
            return uid == euid && isSafeName(name)
        }
        return isOffered(name: name, uid: uid, shell: shell, euid: 0, platform: platform)
    }

    public static func list(
        euid: UInt32 = currentEUID(),
        platform: PlatformKind = currentPlatform,
    ) -> [Record] {
        #if os(Windows)
            _ = euid
            _ = platform
            return []
        #else
            if euid != 0 {
                return lookup(uid: euid).map { [$0] } ?? []
            }
            lock.lock()
            defer { lock.unlock() }
            setpwent()
            defer { endpwent() }
            var seen = Set<String>()
            var records: [Record] = []
            while let pw = getpwent() {
                let record = record(from: pw.pointee)
                guard seen.insert(record.name).inserted else { continue }
                guard isOffered(
                    name: record.name,
                    uid: record.uid,
                    shell: record.shell,
                    euid: 0,
                    platform: platform,
                ) else { continue }
                records.append(record)
            }
            return records.sorted { $0.name < $1.name }
        #endif
    }

    public static func lookup(name: String) -> Record? {
        #if os(Windows)
            _ = name
            return nil
        #else
            guard isSafeName(name) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return name.withCString { ptr in
                guard let pw = getpwnam(ptr) else { return nil }
                return record(from: pw.pointee)
            }
        #endif
    }

    public static func lookup(uid: UInt32) -> Record? {
        #if os(Windows)
            _ = uid
            return nil
        #else
            lock.lock()
            defer { lock.unlock() }
            guard let pw = getpwuid(uid_t(uid)) else { return nil }
            return record(from: pw.pointee)
        #endif
    }

    public static func spawnRecord(
        name: String,
        euid: UInt32 = currentEUID(),
        platform: PlatformKind = currentPlatform,
    ) -> Record? {
        guard let record = lookup(name: name) else { return nil }
        guard isSpawnAllowed(
            name: record.name,
            uid: record.uid,
            shell: record.shell,
            euid: euid,
            platform: platform,
        ) else { return nil }
        return record
    }

    public static func credentials(for record: Record) -> Credentials {
        #if os(Windows)
            return Credentials(uid: record.uid, gid: record.gid, groups: [record.gid])
        #else
            let groups = supplementaryGroups(name: record.name, gid: record.gid)
            let unique = Array(Set([record.gid] + groups))
            return Credentials(uid: record.uid, gid: record.gid, groups: unique)
        #endif
    }

    public static func loginShellPath(for record: Record) -> String {
        let shell = record.shell.trimmingCharacters(in: .whitespacesAndNewlines)
        if shell.hasPrefix("/"), isLoginShell(shell) {
            return shell
        }
        return "/bin/sh"
    }

    public static func loginArgv0(shellPath: String) -> String {
        let base = (shellPath as NSString).lastPathComponent
        return base.isEmpty ? "-sh" : "-\(base)"
    }

    public static func environment(for record: Record, shellPath: String) -> [String] {
        var path = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        #if os(macOS)
            path = "/opt/homebrew/bin:" + path
        #endif
        return [
            "HOME=\(record.home)",
            "USER=\(record.name)",
            "LOGNAME=\(record.name)",
            "SHELL=\(shellPath)",
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "PATH=\(path)",
        ]
    }

    public static func currentEUID() -> UInt32 {
        #if os(Windows)
            return 1_000
        #else
            return UInt32(geteuid())
        #endif
    }

    #if !os(Windows)
        private static func record(from pw: passwd) -> Record {
            Record(
                name: String(cString: pw.pw_name),
                uid: UInt32(pw.pw_uid),
                gid: UInt32(pw.pw_gid),
                home: String(cString: pw.pw_dir),
                shell: String(cString: pw.pw_shell),
            )
        }

        private static func supplementaryGroups(name: String, gid: UInt32) -> [UInt32] {
            name.withCString { ptr in
                #if canImport(Darwin)
                    var count: Int32 = 32
                    var gids = [Int32](repeating: 0, count: Int(count))
                    var rc = getgrouplist(ptr, Int32(gid), &gids, &count)
                    if rc < 0 {
                        gids = [Int32](repeating: 0, count: max(Int(count), 1))
                        rc = getgrouplist(ptr, Int32(gid), &gids, &count)
                    }
                    guard rc >= 0 else { return [gid] }
                    return gids.prefix(Int(count)).map { UInt32(bitPattern: $0) }
                #else
                    var count: Int32 = 32
                    var gids = [gid_t](repeating: 0, count: Int(count))
                    var rc = getgrouplist(ptr, gid_t(gid), &gids, &count)
                    if rc < 0 {
                        gids = [gid_t](repeating: 0, count: max(Int(count), 1))
                        rc = getgrouplist(ptr, gid_t(gid), &gids, &count)
                    }
                    guard rc >= 0 else { return [gid] }
                    return gids.prefix(Int(count)).map { UInt32($0) }
                #endif
            }
        }
    #endif
}
