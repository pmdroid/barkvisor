import Foundation

public struct HostNetworkSnapshot: Codable, Equatable, Sendable {
    public var files: [String: String]
    public var absentPaths: [String]
    public var aclContents: String?

    public init(
        files: [String: String] = [:],
        absentPaths: [String] = [],
        aclContents: String? = nil,
    ) {
        self.files = files
        self.absentPaths = absentPaths
        self.aclContents = aclContents
    }
}

public enum HostNetworkRecoveryPhase {
    public static let mutating = "mutating"
    public static let awaitingConfirmation = "awaitingConfirmation"
    public static let confirmed = "confirmed"
    public static let restoring = "restoring"
    public static let restored = "restored"
    public static let restoreFailed = "restore_failed"
    public static let superseded = "superseded"

    /// Written by daemons before a successful restore became terminal. Those records had
    /// already applied their snapshot, so they settle exactly like `restored` and must
    /// never apply it again.
    public static let legacyReverting = "reverting"

    /// Terminal phases settle an operation: nothing later writes a snapshot for them.
    public static func isTerminal(_ phase: String) -> Bool {
        switch phase {
        case confirmed, restored, superseded, legacyReverting:
            true
        default:
            false
        }
    }

    /// Phases a confirmation must refuse because the host was already moved on.
    public static func settledDescription(_ phase: String) -> String? {
        switch phase {
        case restoring, restoreFailed:
            "is reverting"
        case restored, legacyReverting:
            "already reverted its snapshot"
        case superseded:
            "was superseded by a newer host network operation"
        default:
            nil
        }
    }
}

public struct HostNetworkRecoveryRecord: Codable, Equatable, Sendable {
    public var operationId: String
    public var generation: Int
    public var target: String
    public var phase: String
    public var deadline: Date
    public var snapshot: HostNetworkSnapshot
    /// Restore attempts made so far. Only failures increment it.
    public var restoreAttempts: Int
    public var lastRestoreError: String?
    public var restoredAt: Date?

    public init(
        operationId: String,
        generation: Int,
        target: String,
        phase: String,
        deadline: Date,
        snapshot: HostNetworkSnapshot,
        restoreAttempts: Int = 0,
        lastRestoreError: String? = nil,
        restoredAt: Date? = nil,
    ) {
        self.operationId = operationId
        self.generation = generation
        self.target = target
        self.phase = phase
        self.deadline = deadline
        self.snapshot = snapshot
        self.restoreAttempts = restoreAttempts
        self.lastRestoreError = lastRestoreError
        self.restoredAt = restoredAt
    }

    enum CodingKeys: String, CodingKey {
        case operationId, generation, target, phase, deadline, snapshot
        case restoreAttempts, lastRestoreError, restoredAt
    }

    /// Records written before restore accounting existed decode with zeroed fields, so an
    /// upgraded Device needs no repair pass.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try c.decode(String.self, forKey: .operationId)
        generation = try c.decode(Int.self, forKey: .generation)
        target = try c.decode(String.self, forKey: .target)
        phase = try c.decode(String.self, forKey: .phase)
        deadline = try c.decode(Date.self, forKey: .deadline)
        snapshot = try c.decode(HostNetworkSnapshot.self, forKey: .snapshot)
        restoreAttempts = try c.decodeIfPresent(Int.self, forKey: .restoreAttempts) ?? 0
        lastRestoreError = try c.decodeIfPresent(String.self, forKey: .lastRestoreError)
        restoredAt = try c.decodeIfPresent(Date.self, forKey: .restoredAt)
    }
}

/// Outcome of one expired-record sweep. Each record is handled independently: a failure
/// is recorded on that record and never stops the rest of the sweep.
public struct HostNetworkRecoverySweepResult: Equatable, Sendable {
    public var restored: [String]
    public var superseded: [String]
    public var failed: [String]
    public var deferred: [String]

    public init(
        restored: [String] = [],
        superseded: [String] = [],
        failed: [String] = [],
        deferred: [String] = [],
    ) {
        self.restored = restored
        self.superseded = superseded
        self.failed = failed
        self.deferred = deferred
    }

    public var isEmpty: Bool {
        restored.isEmpty && superseded.isEmpty && failed.isEmpty && deferred.isEmpty
    }
}

/// Injection seam for one sweep. Everything here defaults to the sweep's own `dataDir`
/// and to `FileManager`, so production callers pass nothing and tests can stage a failing
/// restore or a stamped target in a temp directory.
public struct HostNetworkRecoverySweepOptions {
    public var pendingCommits: [HostNetworkPendingCommit]?
    public var stampExists: ((String) -> Bool)?
    public var keepingExists: ((String) -> Bool)?
    public var restore: (HostNetworkSnapshot) throws -> Void

    public init(
        pendingCommits: [HostNetworkPendingCommit]? = nil,
        stampExists: ((String) -> Bool)? = nil,
        keepingExists: ((String) -> Bool)? = nil,
        restore: @escaping (HostNetworkSnapshot) throws -> Void = { try HostNetworkRecovery.restore($0) },
    ) {
        self.pendingCommits = pendingCommits
        self.stampExists = stampExists
        self.keepingExists = keepingExists
        self.restore = restore
    }
}

/// Durable per-operation record of a host network apply, and the sweep that settles it
/// once its confirmation window closes. Records are one JSON file per operation under
/// `{dataDir}/host-network/recovery/`, so an upgraded Device needs no migration.
public enum HostNetworkRecovery {
    public static func capture(paths: [String], aclContents: String? = nil) -> HostNetworkSnapshot {
        var files: [String: String] = [:]
        var absent: [String] = []
        for path in paths {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                files[path] = text
            } else {
                absent.append(path)
            }
        }
        return HostNetworkSnapshot(files: files, absentPaths: absent, aclContents: aclContents)
    }

    public static func begin(
        operationId: String,
        generation: Int,
        target: String,
        snapshot: HostNetworkSnapshot,
        deadline: Date,
        dataDir: URL = Config.dataDir,
    ) throws -> HostNetworkRecoveryRecord {
        try requireOperationId(operationId)
        let record = HostNetworkRecoveryRecord(
            operationId: operationId,
            generation: generation,
            target: target,
            phase: HostNetworkRecoveryPhase.mutating,
            deadline: deadline,
            snapshot: snapshot,
        )
        try save(record, dataDir: dataDir)
        return record
    }

    public static func mark(
        _ operationId: String,
        phase: String,
        dataDir: URL = Config.dataDir,
    ) throws {
        guard var record = load(operationId: operationId, dataDir: dataDir) else {
            throw BarkVisorError.notFound("No host network recovery record for \(operationId)")
        }
        record.phase = phase
        try save(record, dataDir: dataDir)
    }

    public static func load(operationId: String, dataDir: URL = Config.dataDir) -> HostNetworkRecoveryRecord? {
        guard let url = try? recordURL(operationId: operationId, dataDir: dataDir) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HostNetworkRecoveryRecord.self, from: data)
    }

    public static func list(dataDir: URL = Config.dataDir) -> [HostNetworkRecoveryRecord] {
        let dir = dataDir.appendingPathComponent("host-network/recovery", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(HostNetworkRecoveryRecord.self, from: data)
        }
    }

    public static func requireConfirmation(
        pending: HostNetworkPendingCommit,
        requestedOperationId: String?,
        requestedGeneration: Int?,
        authorized: Bool,
        now: Date = Date(),
        dataDir: URL = Config.dataDir,
    ) throws {
        if !authorized {
            throw BarkVisorError.unauthorized("Host network confirmation is not authorized")
        }
        if now >= pending.commitDeadline {
            throw BarkVisorError.badRequest(
                "Pending apply expired. Network may have auto-reverted — run Revert to clean up.",
            )
        }
        guard let storedOperation = pending.operationId else { return }
        // A pruned record means the operation settled long ago: the deadline check above
        // already answers the common late-confirmation case, so reaching here means the
        // pending commit outlived its own record.
        guard let record = load(operationId: storedOperation, dataDir: dataDir) else {
            throw BarkVisorError.conflict(
                "Host network recovery record for \(storedOperation) is no longer available",
            )
        }
        if let settled = HostNetworkRecoveryPhase.settledDescription(record.phase) {
            throw BarkVisorError.conflict("Host network operation \(storedOperation) \(settled)")
        }
        if record.phase == HostNetworkRecoveryPhase.confirmed { return }
        let operationId = requestedOperationId ?? storedOperation
        let generation = requestedGeneration ?? record.generation
        guard operationId == storedOperation else {
            throw BarkVisorError.conflict(
                "Confirmation does not match pending host network operation \(storedOperation)",
            )
        }
        guard generation == record.generation else {
            throw BarkVisorError.conflict(
                "Stale confirmation cannot commit host network operation \(storedOperation)",
            )
        }
        if now >= record.deadline {
            throw BarkVisorError.badRequest(
                "Pending apply expired. Network may have auto-reverted — run Revert to clean up.",
            )
        }
    }

    /// Restores captured files and removes paths that were absent when the snapshot was
    /// taken. The file-system seam is injectable so a failing restore is testable without
    /// touching a real host.
    public static func restore(
        _ snapshot: HostNetworkSnapshot,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        makeDirectory: (URL) throws -> Void = { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        write: (URL, String) throws -> Void = { url, body in
            try body.write(to: url, atomically: true, encoding: .utf8)
        },
        remove: (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) },
    ) throws {
        for (path, body) in snapshot.files {
            let url = URL(fileURLWithPath: path)
            try makeDirectory(url.deletingLastPathComponent())
            try write(url, body)
        }
        for path in snapshot.absentPaths where fileExists(path) {
            try remove(path)
        }
    }

    /// Settles every expired recovery record that still owns its target.
    ///
    /// The newest `generation` for a target owns that target's files. An older expired
    /// record is marked `superseded` without writing anything, so it can never clobber a
    /// newer confirmed apply — including after a daemon restart, because ownership is
    /// recomputed from the records on disk on every sweep. Each record is handled
    /// independently: a failed restore is recorded and retried on the next sweep without
    /// stopping the rest of the sweep.
    ///
    /// Callers run this inside the per-target `claimRevert` gate and re-check the commit
    /// stamp after claiming.
    @discardableResult
    public static func sweepExpired(
        dataDir: URL = Config.dataDir,
        now: Date = Date(),
        target: String? = nil,
        options: HostNetworkRecoverySweepOptions = HostNetworkRecoverySweepOptions(),
    ) -> HostNetworkRecoverySweepResult {
        var result = HostNetworkRecoverySweepResult()
        guard PendingNetworkUsePolicy.expiredUnconfirmedReverts() else { return result }
        // Probes default to this sweep's dataDir so a caller cannot accidentally check the
        // live Device's stamp while sweeping a temp directory.
        let stamped = options.stampExists ?? { HostNetworkPendingCommitService.stampExists($0, dataDir: dataDir) }
        let keeping = options.keepingExists ?? { HostNetworkPendingCommitService.keepingExists($0, dataDir: dataDir) }
        let pendings = options.pendingCommits ?? HostNetworkPendingCommitService.listPending(dataDir: dataDir)
        prune(dataDir: dataDir, now: now)
        let candidates = list(dataDir: dataDir)
            .filter { target == nil || $0.target == target }
            .sorted { $0.generation == $1.generation ? $0.operationId < $1.operationId : $0.generation < $1.generation }
        guard !candidates.isEmpty else { return result }
        let owners = Dictionary(grouping: candidates, by: \.target)
            .mapValues { group in group.map(\.generation).max() }
        for record in candidates {
            do {
                switch try settle(
                    record,
                    SettleContext(
                        dataDir: dataDir,
                        now: now,
                        ownerGeneration: owners[record.target] ?? record.generation,
                        pendings: pendings,
                        stampExists: stamped,
                        keepingExists: keeping,
                        restore: options.restore,
                    ),
                ) {
                case .restored:
                    result.restored.append(record.operationId)
                case .superseded:
                    result.superseded.append(record.operationId)
                case .deferred:
                    result.deferred.append(record.operationId)
                case .failed:
                    result.failed.append(record.operationId)
                case .skipped:
                    continue
                }
            } catch {
                // A record that cannot even be persisted stays as it is and is retried.
                result.failed.append(record.operationId)
            }
        }
        return result
    }

    /// Everything one record's settlement needs besides the record itself.
    private struct SettleContext {
        var dataDir: URL
        var now: Date
        var ownerGeneration: Int?
        var pendings: [HostNetworkPendingCommit]
        var stampExists: (String) -> Bool
        var keepingExists: (String) -> Bool
        var restore: (HostNetworkSnapshot) throws -> Void
    }

    private enum Settlement {
        case restored
        case superseded
        case deferred
        case failed
        case skipped
    }

    private static func settle(
        _ record: HostNetworkRecoveryRecord,
        _ context: SettleContext,
    ) throws -> Settlement {
        guard !HostNetworkRecoveryPhase.isTerminal(record.phase) else { return .skipped }
        guard context.now >= record.deadline else { return .skipped }
        if let ownerGeneration = context.ownerGeneration, ownerGeneration > record.generation {
            var next = record
            next.phase = HostNetworkRecoveryPhase.superseded
            try save(next, dataDir: context.dataDir)
            return .superseded
        }
        let live = context.pendings.filter { $0.target == record.target }
        if context.stampExists(record.target)
            || context.keepingExists(record.target)
            || HostNetworkPendingCommitService.blockingPending(target: record.target, existing: live) != nil {
            return .deferred
        }
        var next = record
        next.phase = HostNetworkRecoveryPhase.restoring
        try? save(next, dataDir: context.dataDir)
        do {
            try context.restore(record.snapshot)
        } catch {
            next.phase = HostNetworkRecoveryPhase.restoreFailed
            next.restoreAttempts += 1
            next.lastRestoreError = String(describing: error)
            try? save(next, dataDir: context.dataDir)
            return .failed
        }
        next.phase = HostNetworkRecoveryPhase.restored
        next.restoredAt = context.now
        next.lastRestoreError = nil
        try? save(next, dataDir: context.dataDir)
        return .restored
    }

    /// Deletes terminal records once they are old enough that no live confirmation can
    /// still be waiting on them, so `list()` stays bounded.
    @discardableResult
    public static func prune(
        dataDir: URL = Config.dataDir,
        now: Date = Date(),
        retention: TimeInterval = terminalRetention,
    ) -> [String] {
        let dir = dataDir.appendingPathComponent("host-network/recovery", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var pruned: [String] = []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(HostNetworkRecoveryRecord.self, from: data),
                  HostNetworkRecoveryPhase.isTerminal(record.phase)
            else { continue }
            let settledAt = record.restoredAt
                ?? (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                ?? record.deadline
            guard now.timeIntervalSince(settledAt) >= retention else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                pruned.append(record.operationId)
            }
        }
        return pruned
    }

    /// How long a terminal record is kept. Far longer than the confirmation window, so a
    /// late confirmation still reads a real phase instead of a missing file; after that
    /// `requireConfirmation` answers from the pending commit's own deadline.
    public static let terminalRetention: TimeInterval = 24 * 60 * 60

    public static func save(_ record: HostNetworkRecoveryRecord, dataDir: URL = Config.dataDir) throws {
        let url = try recordURL(operationId: record.operationId, dataDir: dataDir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    private static func recordURL(operationId: String, dataDir: URL) throws -> URL {
        try requireOperationId(operationId)
        return dataDir
            .appendingPathComponent("host-network/recovery", isDirectory: true)
            .appendingPathComponent("\(operationId).json")
    }

    private static func requireOperationId(_ operationId: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !operationId.isEmpty, operationId.count <= 80,
              operationId.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw BarkVisorError.badRequest("Host network operation id is not a single path segment")
        }
    }
}
