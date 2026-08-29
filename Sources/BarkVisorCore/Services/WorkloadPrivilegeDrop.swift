import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// How the root Device daemon launches QEMU / swtpm so guests do not inherit uid 0.
///
/// Linux: when the daemon is root, wrap with `setpriv` (or `runuser`) as
/// `barkvisor` then `qemu`, using that user's groups (`kvm` / `disk` from postinst).
/// macOS: QEMU stays the daemon uid. HVF and USB passthrough have not been
/// proven after a drop; do not wrap until they are.
public enum WorkloadPrivilegeDrop {
    public static let preferredUsers = ["barkvisor", "qemu"]
    public static let setprivPath = "/usr/bin/setpriv"
    public static let runuserPaths = ["/usr/sbin/runuser", "/sbin/runuser"]

    public struct Launch: Equatable, Sendable {
        public let executable: URL
        public let arguments: [String]
        public let dropped: Bool
        public let user: String?
        public let reason: String

        public init(
            executable: URL,
            arguments: [String],
            dropped: Bool,
            user: String?,
            reason: String,
        ) {
            self.executable = executable
            self.arguments = arguments
            self.dropped = dropped
            self.user = user
            self.reason = reason
        }
    }

    /// Live spawn plan for this process.
    public static func apply(executable: URL, arguments: [String]) -> Launch {
        plan(
            executable: executable,
            arguments: arguments,
            euid: currentEUID(),
            dropsOnPlatform: dropsOnThisPlatform,
            userExists: userAccountExists,
            wrapperPath: firstExistingWrapper,
        )
    }

    public static var dropsOnThisPlatform: Bool {
        #if os(Linux)
            true
        #else
            false
        #endif
    }

    public static func plan(
        executable: URL,
        arguments: [String],
        euid: uid_t,
        dropsOnPlatform: Bool,
        userExists: (String) -> Bool,
        wrapperPath: (String) -> String?,
    ) -> Launch {
        let unchanged = Launch(
            executable: executable,
            arguments: arguments,
            dropped: false,
            user: nil,
            reason: "unchanged",
        )
        guard dropsOnPlatform else {
            return Launch(
                executable: executable,
                arguments: arguments,
                dropped: false,
                user: nil,
                reason: "macOS HVF and USB passthrough are unproven after a uid drop; "
                    + "QEMU stays the daemon uid (root on appliance installs)",
            )
        }
        guard euid == 0 else {
            return Launch(
                executable: executable,
                arguments: arguments,
                dropped: false,
                user: nil,
                reason: "daemon is not root; QEMU inherits the current uid",
            )
        }
        guard let user = preferredUsers.first(where: userExists) else {
            return Launch(
                executable: executable,
                arguments: arguments,
                dropped: false,
                user: nil,
                reason: "no barkvisor/qemu user; QEMU inherits uid 0",
            )
        }
        if let setpriv = wrapperPath(setprivPath) {
            return Launch(
                executable: URL(fileURLWithPath: setpriv),
                arguments: setprivArguments(user: user, executable: executable, arguments: arguments),
                dropped: true,
                user: user,
                reason: "setpriv --reuid=\(user) --init-groups",
            )
        }
        for path in runuserPaths {
            if let runuser = wrapperPath(path) {
                return Launch(
                    executable: URL(fileURLWithPath: runuser),
                    arguments: ["-u", user, "--", executable.path] + arguments,
                    dropped: true,
                    user: user,
                    reason: "runuser -u \(user)",
                )
            }
        }
        return Launch(
            executable: executable,
            arguments: arguments,
            dropped: false,
            user: user,
            reason: "setpriv/runuser missing; QEMU inherits uid 0",
        )
    }

    public static func setprivArguments(
        user: String,
        executable: URL,
        arguments: [String],
    ) -> [String] {
        [
            "--reuid=\(user)",
            "--regid=\(user)",
            "--init-groups",
            "--inh-caps=-all",
            "--",
            executable.path,
        ] + arguments
    }

    /// Files `0660`, directories `0770`, so the drop user can write via group
    /// when the daemon created the path as `root:barkvisor`.
    public static func handoffMode(isDirectory: Bool) -> Int {
        isDirectory ? 0o770 : 0o660
    }

    /// User QEMU / swtpm will run as, if this process would drop. Nil on macOS,
    /// when not root, or when no `barkvisor` / `qemu` account exists.
    public static func dropUserIfNeeded(
        euid: uid_t,
        dropsOnPlatform: Bool,
        userExists: (String) -> Bool,
    ) -> String? {
        guard dropsOnPlatform, euid == 0 else { return nil }
        return preferredUsers.first(where: userExists)
    }

    /// After qemu-img / copyItem / createDirectory as root, chown+chmod so the
    /// dropped user can write. No-op when this process would not drop.
    ///
    /// `copyItem` from `/usr/share` keeps 0644 (UMask does not apply). Disks and
    /// TPM dirs created under systemd default umask 0022 are group-read only.
    public static func handoffForDroppedUser(_ path: URL) throws {
        guard let user = dropUserIfNeeded(
            euid: currentEUID(),
            dropsOnPlatform: dropsOnThisPlatform,
            userExists: userAccountExists,
        ) else { return }
        guard let ids = posixIDs(forUser: user) else {
            throw BarkVisorError.internalError("drop user \(user) has no passwd entry")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        try applyHandoff(path, uid: ids.uid, gid: ids.gid, mode: handoffMode(isDirectory: isDir))
    }

    package static func applyHandoff(_ path: URL, uid: uid_t, gid: gid_t, mode: Int) throws {
        do {
            try FileManager.default.setAttributes(
                [
                    .ownerAccountID: NSNumber(value: uid),
                    .groupOwnerAccountID: NSNumber(value: gid),
                    .posixPermissions: mode,
                ],
                ofItemAtPath: path.path,
            )
        } catch {
            throw BarkVisorError.internalError(
                "handoff \(path.path) to uid \(uid) gid \(gid) mode "
                    + String(mode, radix: 8)
                    + " failed: \(error.localizedDescription)",
            )
        }
    }

    public static func currentEUID() -> uid_t {
        geteuid()
    }

    private static func userAccountExists(_ name: String) -> Bool {
        posixIDs(forUser: name) != nil
    }

    private static func posixIDs(forUser name: String) -> (uid: uid_t, gid: gid_t)? {
        name.withCString { ptr in
            guard let pw = getpwnam(ptr) else { return nil }
            return (pw.pointee.pw_uid, pw.pointee.pw_gid)
        }
    }

    private static func firstExistingWrapper(_ path: String) -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
