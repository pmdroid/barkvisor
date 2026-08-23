import Foundation

/// Coding session lifecycle (PAS-273): TTL stop, receipt, resume / reset / burn.
public struct CodingAgentReceipt: Codable, Equatable, Sendable {
    public var stoppedAt: String
    public var reason: String
    public var lastGitPushAt: String?
    public var noPush: Bool

    public init(stoppedAt: String, reason: String, lastGitPushAt: String?, noPush: Bool) {
        self.stoppedAt = stoppedAt
        self.reason = reason
        self.lastGitPushAt = lastGitPushAt
        self.noPush = noPush
    }
}

public struct CodingAgentSessionState: Codable, Equatable, Sendable {
    public var ttlSeconds: Int
    public var startedAt: String?
    public var expiresAt: String?
    public var warnedAt: String?
    public var grant: String
    public var cloudImageId: String?
    public var diskSizeGB: Int?
    public var receipt: CodingAgentReceipt?
    /// Stop reason captured while the guest is still up. Promoted to `receipt` in
    /// `handleTermination`. Not part of the API view.
    public var pendingStopReason: String?
    /// Git stamp snapshotted at stop request, before the guest-agent socket dies.
    public var pendingGitStamp: String?

    public init(
        ttlSeconds: Int,
        startedAt: String? = nil,
        expiresAt: String? = nil,
        warnedAt: String? = nil,
        grant: String,
        cloudImageId: String? = nil,
        diskSizeGB: Int? = nil,
        receipt: CodingAgentReceipt? = nil,
        pendingStopReason: String? = nil,
        pendingGitStamp: String? = nil,
    ) {
        self.ttlSeconds = ttlSeconds
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.warnedAt = warnedAt
        self.grant = grant
        self.cloudImageId = cloudImageId
        self.diskSizeGB = diskSizeGB
        self.receipt = receipt
        self.pendingStopReason = pendingStopReason
        self.pendingGitStamp = pendingGitStamp
    }
}

/// API / client projection. Remaining time is computed at read, not stored.
public struct CodingAgentSessionView: Codable, Equatable, Sendable {
    public var ttlSeconds: Int
    public var startedAt: String?
    public var expiresAt: String?
    public var remainingSeconds: Int?
    public var warning: Bool
    public var warningLeadSeconds: Int
    public var expiryAction: String
    public var grant: String
    public var receipt: CodingAgentReceipt?
    public var actions: [String]

    public init(
        ttlSeconds: Int,
        startedAt: String?,
        expiresAt: String?,
        remainingSeconds: Int?,
        warning: Bool,
        warningLeadSeconds: Int,
        expiryAction: String,
        grant: String,
        receipt: CodingAgentReceipt?,
        actions: [String],
    ) {
        self.ttlSeconds = ttlSeconds
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.remainingSeconds = remainingSeconds
        self.warning = warning
        self.warningLeadSeconds = warningLeadSeconds
        self.expiryAction = expiryAction
        self.grant = grant
        self.receipt = receipt
        self.actions = actions
    }
}

public enum CodingAgentLifecycle {
    public static let defaultTTLSeconds = 4 * 60 * 60
    public static let warningLeadSeconds = 15 * 60
    public static let gitStampPath = "/var/lib/barkvisor/last-git-push"
    public static let expiryAction = "stop"
    public static let actions = ["resume", "reset", "burn"]
    public static let noPushCopy = "NO PUSH"
    public static let ttlReason = "ttl"
    public static let stopReason = "stop"
    public static let forceReason = "force"
    public static let resetReason = "reset"
    public static let burnReason = "burn"

    public static func isSessionLive(_ vmState: String) -> Bool {
        vmState == "running" || vmState == "starting" || vmState == "stopping"
    }

    public static func visibleReceipt(
        _ receipt: CodingAgentReceipt?,
        vmState: String,
    ) -> CodingAgentReceipt? {
        isSessionLive(vmState) ? nil : receipt
    }

    /// Kill and TTL unload models. Graceful ACPI stop keeps them for Resume.
    public static func shouldUnloadGrantAfterStop(reason: String) -> Bool {
        reason == ttlReason || reason == forceReason || reason == burnReason
    }

    public static func normalizeTTL(_ raw: Int?) -> Int {
        let value = raw ?? defaultTTLSeconds
        return min(max(value, 60), 7 * 24 * 60 * 60)
    }

    public static func seed(
        ttlSeconds: Int? = nil,
        grant: String,
        cloudImageId: String?,
        diskSizeGB: Int?,
    ) -> CodingAgentSessionState {
        CodingAgentSessionState(
            ttlSeconds: normalizeTTL(ttlSeconds),
            grant: grant,
            cloudImageId: cloudImageId,
            diskSizeGB: diskSizeGB,
        )
    }

    public static func parseInstant(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let date = iso8601.date(from: trimmed) { return date }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    public static func remainingSeconds(expiresAt: String?, now: Date) -> Int? {
        guard let expiry = parseInstant(expiresAt) else { return nil }
        return Int(expiry.timeIntervalSince(now).rounded(.down))
    }

    public static func shouldWarn(expiresAt: String?, warnedAt: String?, now: Date) -> Bool {
        guard let remaining = remainingSeconds(expiresAt: expiresAt, now: now) else { return false }
        return remaining <= warningLeadSeconds && remaining > 0 && warnedAt == nil
    }

    public static func isWarningActive(expiresAt: String?, now: Date) -> Bool {
        guard let remaining = remainingSeconds(expiresAt: expiresAt, now: now) else { return false }
        return remaining <= warningLeadSeconds && remaining > 0
    }

    public static func shouldExpire(expiresAt: String?, vmState: String, now: Date) -> Bool {
        guard vmState == "running" || vmState == "starting" else { return false }
        guard let remaining = remainingSeconds(expiresAt: expiresAt, now: now) else { return false }
        return remaining <= 0
    }

    public static func beginClock(_ state: inout CodingAgentSessionState, now: Date) {
        state.receipt = nil
        state.pendingStopReason = nil
        state.pendingGitStamp = nil
        if let remaining = remainingSeconds(expiresAt: state.expiresAt, now: now), remaining > 0 {
            return
        }
        state.startedAt = iso8601.string(from: now)
        state.expiresAt = iso8601.string(from: now.addingTimeInterval(TimeInterval(state.ttlSeconds)))
        state.warnedAt = nil
    }

    public static func parseGitStamp(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = parseInstant(trimmed) else { return nil }
        return iso8601.string(from: date)
    }

    public static func makeReceipt(now: Date, reason: String, lastGitPushAt: String?) -> CodingAgentReceipt {
        let push = parseGitStamp(lastGitPushAt)
        return CodingAgentReceipt(
            stoppedAt: iso8601.string(from: now),
            reason: reason,
            lastGitPushAt: push,
            noPush: push == nil,
        )
    }

    public static func view(
        _ state: CodingAgentSessionState,
        now: Date,
        vmState: String,
    ) -> CodingAgentSessionView {
        let remaining = remainingSeconds(expiresAt: state.expiresAt, now: now)
        let live = vmState == "running" || vmState == "starting"
        let remainingLive = live ? remaining : remaining.flatMap { $0 > 0 ? $0 : nil }
        return CodingAgentSessionView(
            ttlSeconds: state.ttlSeconds,
            startedAt: state.startedAt,
            expiresAt: state.expiresAt,
            remainingSeconds: remainingLive,
            warning: live && isWarningActive(expiresAt: state.expiresAt, now: now),
            warningLeadSeconds: warningLeadSeconds,
            expiryAction: expiryAction,
            grant: state.grant,
            receipt: visibleReceipt(state.receipt, vmState: vmState),
            actions: actions,
        )
    }

    public static func usesHomeOllamaGrant(_ grant: String) -> Bool {
        grant == CodingAgentSession.grant
    }

    public static func shouldUnloadGrant(usesHomeOllama: Bool, otherRunningAgentSessions: Int) -> Bool {
        usesHomeOllama && otherRunningAgentSessions <= 0
    }
}

/// Start/stop/occupancy used by coding-session TTL. Tests pass a fake.
public protocol CodingAgentControlling: Sendable {
    func stop(vmID: String, force: Bool, method: String) async throws
    func start(vmID: String) async throws
    func isActiveOrStarting(_ vmID: String) async -> Bool
}

/// Unload Home Ollama models. Tests pass a recorder instead of a live client.
public protocol CodingAgentModelUnloading: Sendable {
    func unloadRunningModels() async throws
}
