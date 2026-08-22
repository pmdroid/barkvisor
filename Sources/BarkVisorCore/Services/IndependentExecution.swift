import Foundation

/// PAS-90: this Device's SQLite + QEMU are process authority. Home inventory is
/// an index. A controller, peer, or reconnect must not drive runtime.
public enum IndependentExecution {
    /// Live migration is a later product idea. The contract must not grow a
    /// migrate route until that work is explicit.
    public static let forbiddenPathTokens = ["migrate", "live-migration", "livemigrate"]

    /// SIGKILL is only for an explicit Force Stop (`force` or method `force`).
    /// ACPI stop, reconnect, and Home inventory must not escalate to kill.
    public static func allowsHardKill(force: Bool, method: String) -> Bool {
        force || method == "force"
    }

    public static func contractAllowsLiveMigration(paths: [String]) -> Bool {
        paths.contains { path in
            let lowered = path.lowercased()
            return forbiddenPathTokens.contains { token in
                pathHasToken(lowered, token: token)
            }
        }
    }

    public enum ReconnectAction: Equatable, Sendable {
        /// Already adopted in this process — do not re-attach or signal.
        case skipAlreadyRegistered
        /// QEMU is alive and this Device owns the Workload row — adopt, even if
        /// QMP sockets are briefly missing. Never SIGKILL on reconnect.
        case adopt
        /// PID file is stale; process is gone.
        case cleanupDead
        /// PID was reused by a non-QEMU process — drop the pid file, do not kill.
        case cleanupPidReuse
        /// QEMU is alive but SQLite has no Workload. Not a Home-indexed guest.
        case cleanupOrphanNoRecord
    }

    /// Decide reconnect without looking at sockets. Missing QMP must not thrash
    /// a live QEMU child.
    public static func reconnectAction(
        alreadyRegistered: Bool,
        processAlive: Bool,
        isQEMU: Bool,
        hasDBRecord: Bool,
    ) -> ReconnectAction {
        if alreadyRegistered { return .skipAlreadyRegistered }
        if !processAlive { return .cleanupDead }
        if !isQEMU { return .cleanupPidReuse }
        if !hasDBRecord { return .cleanupOrphanNoRecord }
        return .adopt
    }

    private static func pathHasToken(_ path: String, token: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased() == token }
    }
}
