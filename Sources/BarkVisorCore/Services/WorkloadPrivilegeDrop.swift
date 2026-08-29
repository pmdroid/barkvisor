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
/// Disks, UEFI VARS, and TPM state are created as the daemon (root:barkvisor,
/// umask 0022 → 0644 / 0755). `handoffWritable` chowns those paths to the drop
/// user so the dropped process can open them read-write.
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
        guard let user = dropUser(
            euid: euid,
            dropsOnPlatform: dropsOnPlatform,
            userExists: userExists,
        ) else {
            if !dropsOnPlatform {
                return Launch(
                    executable: executable,
                    arguments: arguments,
                    dropped: false,
                    user: nil,
                    reason: "macOS HVF and USB passthrough are unproven after a uid drop; "
                        + "QEMU stays the daemon uid (root on appliance installs)",
                )
            }
            if euid != 0 {
                return Launch(
                    executable: executable,
                    arguments: arguments,
                    dropped: false,
                    user: nil,
                    reason: "daemon is not root; QEMU inherits the current uid",
                )
            }
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

    /// User QEMU / swtpm will run as after a drop, or nil when we do not drop.
    public static func dropUser(
        euid: uid_t,
        dropsOnPlatform: Bool,
        userExists: (String) -> Bool,
    ) -> String? {
        guard dropsOnPlatform, euid == 0 else { return nil }
        return preferredUsers.first(where: userExists)
    }

    /// Directory mode so dropped swtpm can create TPM state; file mode so
    /// dropped QEMU can write disks and UEFI VARS.
    public static func writableMode(isDirectory: Bool) -> Int {
        isDirectory ? 0o770 : 0o660
    }

    /// Chown `url` to the drop user and chmod it group-writable. No-op when we
    /// do not drop, the path is missing, or it is a host block device.
    public static func handoffWritable(_ url: URL) throws {
        guard let user = dropUser(
            euid: currentEUID(),
            dropsOnPlatform: dropsOnThisPlatform,
            userExists: userAccountExists,
        ) else { return }
        try applyOwnership(url, user: user)
    }

    public static func currentEUID() -> uid_t {
        geteuid()
    }

    static func applyOwnership(_ url: URL, user: String) throws {
        let path = url.path
        if DiskSettings.isHostDevicePath(path) { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        let ids: (uid_t, gid_t)? = user.withCString { ptr in
            guard let pw = getpwnam(ptr) else { return nil }
            return (pw.pointee.pw_uid, pw.pointee.pw_gid)
        }
        guard let (uid, gid) = ids else { return }
        let mode = writableMode(isDirectory: isDir.boolValue)
        do {
            try FileManager.default.setAttributes(
                [
                    .ownerAccountID: uid,
                    .groupOwnerAccountID: gid,
                    .posixPermissions: mode,
                ],
                ofItemAtPath: path,
            )
        } catch {
            throw BarkVisorError.internalError(
                "could not hand off \(path) to \(user) for dropped QEMU: \(error.localizedDescription)",
            )
        }
    }

    private static func userAccountExists(_ name: String) -> Bool {
        name.withCString { ptr in
            getpwnam(ptr) != nil
        }
    }

    private static func firstExistingWrapper(_ path: String) -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
