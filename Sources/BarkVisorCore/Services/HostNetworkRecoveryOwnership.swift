import Foundation

// Who owns what a host network apply may write.
//
// Ownership is not per target. A Linux bridge snapshot always contains the shared
// `/etc/systemd/network/90-barkvisor-*` units, so two different targets claim the same
// files, and the per-target revert gate cannot protect them. A record claims its target
// plus every path in its snapshot, and may write only while no strictly newer record
// claims any of them.

/// Orders records and tracks what each one claims, so a sweep can tell whether a record
/// is still the newest claimant of everything it would write.
struct HostNetworkRecoveryOwnership {
    struct Order: Comparable {
        let generation: Int
        let startedAt: Date
        let operationId: String

        static func < (lhs: Order, rhs: Order) -> Bool {
            if lhs.generation != rhs.generation { return lhs.generation < rhs.generation }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.operationId < rhs.operationId
        }
    }

    /// A record predates `startedAt` when an older daemon wrote it. Such a record must
    /// never outrank a newer one, so it sorts oldest of all.
    private let orders: [String: Order]
    private let claims: [String: Set<String>]

    init(records: [HostNetworkRecoveryRecord]) {
        var orders: [String: Order] = [:]
        var claims: [String: Set<String>] = [:]
        for record in records {
            orders[record.operationId] = Order(
                generation: record.generation,
                startedAt: record.startedAt ?? .distantPast,
                operationId: record.operationId,
            )
            // A superseded record never wrote and never will, so it owns nothing and
            // cannot keep blocking older records.
            claims[record.operationId] = record.phase == HostNetworkRecoveryPhase.superseded
                ? []
                : Self.claims(of: record)
        }
        self.orders = orders
        self.claims = claims
    }

    static func claims(of record: HostNetworkRecoveryRecord) -> Set<String> {
        record.claimedPaths.union(["target:\(record.target)"])
    }

    func order(of record: HostNetworkRecoveryRecord) -> Order {
        orders[record.operationId] ?? Order(
            generation: record.generation,
            startedAt: record.startedAt ?? .distantPast,
            operationId: record.operationId,
        )
    }

    /// True when some strictly newer record claims this record's target or any path in
    /// its snapshot, on any target.
    func isOutranked(_ record: HostNetworkRecoveryRecord) -> Bool {
        isOutranked(record, in: self)
    }

    /// The same question against a freshly read set of records, for the moment just
    /// before a record writes.
    func isOutranked(_ record: HostNetworkRecoveryRecord, in fresh: HostNetworkRecoveryOwnership) -> Bool {
        let mine = Self.claims(of: record)
        guard !mine.isEmpty else { return false }
        let order = fresh.order(of: record)
        return fresh.orders.contains { id, other in
            other > order && !(fresh.claims[id] ?? []).isDisjoint(with: mine)
        }
    }
}
