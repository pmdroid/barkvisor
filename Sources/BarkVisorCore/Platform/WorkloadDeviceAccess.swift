import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

public struct DeviceNodeFacts: Equatable, Sendable {
    public var uid: UInt32
    public var gid: UInt32
    public var mode: UInt32

    public init(uid: UInt32, gid: UInt32, mode: UInt32) {
        self.uid = uid
        self.gid = gid
        self.mode = mode
    }
}

public struct AcceleratorReport: Equatable, Sendable {
    public var accelerator: String
    public var install: String
    public var deviceNodeExists: Bool
    public var workloadCanOpen: Bool

    public init(accelerator: String, install: String, deviceNodeExists: Bool, workloadCanOpen: Bool) {
        self.accelerator = accelerator
        self.install = install
        self.deviceNodeExists = deviceNodeExists
        self.workloadCanOpen = workloadCanOpen
    }
}

public enum WorkloadDeviceAccess {
    public static let applianceDataDir = "/var/lib/barkvisor"
    public static let kvmPath = "/dev/kvm"

    public static func installKind(dataDir: String) -> String {
        dataDir == applianceDataDir ? "appliance" : "development"
    }

    public static func canOpen(
        workloadUID: UInt32,
        workloadGIDs: [UInt32],
        node: DeviceNodeFacts?,
    ) -> Bool {
        guard let node else { return false }
        if workloadUID == 0 { return true }
        if workloadUID == node.uid, (node.mode & 0o600) == 0o600 { return true }
        if workloadGIDs.contains(node.gid), (node.mode & 0o060) == 0o060 { return true }
        return (node.mode & 0o006) == 0o006
    }

    public static func report(
        platform: String,
        dataDir: String,
        deviceNodeExists: Bool,
        workloadCanOpen: Bool,
        windowsWHPX: Bool = false,
    ) -> AcceleratorReport {
        let install = installKind(dataDir: dataDir)
        let accelerator: String = if platform.caseInsensitiveCompare("macOS") == .orderedSame {
            "hvf"
        } else if platform.caseInsensitiveCompare("Linux") == .orderedSame {
            workloadCanOpen ? "kvm" : "tcg"
        } else if platform.caseInsensitiveCompare("Windows") == .orderedSame {
            windowsWHPX ? "whpx" : "tcg"
        } else {
            "tcg"
        }
        return AcceleratorReport(
            accelerator: accelerator,
            install: install,
            deviceNodeExists: deviceNodeExists,
            workloadCanOpen: workloadCanOpen,
        )
    }

    public static func workloadIdentity(
        euid: UInt32,
        dropsOnPlatform: Bool,
        lookup: (String) -> (uid: UInt32, groups: [UInt32])?,
        currentGroups: [UInt32],
    ) -> (uid: UInt32, groups: [UInt32]) {
        if let name = WorkloadPrivilegeDrop.dropUser(
            euid: euid,
            dropsOnPlatform: dropsOnPlatform,
            userExists: { lookup($0) != nil },
        ), let record = lookup(name) {
            return (record.uid, record.groups)
        }
        return (euid, currentGroups)
    }

    public static func liveLinuxKVM() -> Bool {
        #if os(Linux)
            let node = nodeFacts(kvmPath)
            let identity = liveWorkloadIdentity()
            return canOpen(workloadUID: identity.uid, workloadGIDs: identity.groups, node: node)
        #else
            false
        #endif
    }

    public static func linuxAccelerator() -> String {
        liveLinuxKVM() ? "kvm" : "tcg"
    }

    #if os(Linux)
        private static func liveWorkloadIdentity() -> (uid: UInt32, groups: [UInt32]) {
            let euid = WorkloadPrivilegeDrop.currentEUID()
            return workloadIdentity(
                euid: euid,
                dropsOnPlatform: WorkloadPrivilegeDrop.dropsOnThisPlatform,
                lookup: lookupAccount,
                currentGroups: currentGroupList(),
            )
        }

        private static func lookupAccount(_ name: String) -> (uid: UInt32, groups: [UInt32])? {
            name.withCString { pointer -> (uid: UInt32, groups: [UInt32])? in
                guard let password = getpwnam(pointer) else { return nil }
                let uid = password.pointee.pw_uid
                let gid = password.pointee.pw_gid
                return (uid, groups(for: name, primary: gid))
            }
        }

        private static func groups(for name: String, primary: gid_t) -> [UInt32] {
            var count = Int32(64)
            var storage = [gid_t](repeating: 0, count: Int(count))
            let first = name.withCString { pointer in
                getgrouplist(pointer, primary, &storage, &count)
            }
            if first < 0, count > 0 {
                storage = [gid_t](repeating: 0, count: Int(count))
                let second = name.withCString { pointer in
                    getgrouplist(pointer, primary, &storage, &count)
                }
                if second < 0 { return [primary] }
            }
            if count < 0 { return [primary] }
            return storage.prefix(Int(count)).map { UInt32($0) }
        }

        private static func currentGroupList() -> [UInt32] {
            let count = getgroups(0, nil)
            guard count > 0 else { return [UInt32(getegid())] }
            var storage = [gid_t](repeating: 0, count: Int(count))
            let read = storage.withUnsafeMutableBufferPointer { buffer in
                getgroups(count, buffer.baseAddress)
            }
            guard read > 0 else { return [UInt32(getegid())] }
            return storage.prefix(Int(read)).map { UInt32($0) }
        }

        private static func nodeFacts(_ path: String) -> DeviceNodeFacts? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return DeviceNodeFacts(
                uid: info.st_uid,
                gid: info.st_gid,
                mode: UInt32(info.st_mode) & 0o777,
            )
        }
    #endif
}
