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
    /// Apply order, taken from the wall clock the apply began.
    ///
    /// `generation` is deliberately not part of this. It comes from each request
    /// (`request.generation ?? 1`), so it is per target and per caller: an old br0 record
    /// can carry generation 2 while a much newer br1 record carries 1, and comparing
    /// generations across targets would hand the older apply the win. Only the apply
    /// timestamp orders records globally.
    struct Order {
        let startedAt: Date?
        let operationId: String

        /// Records written before `startedAt` existed cannot be placed in apply order, and
        /// a record that cannot be placed must never win a claim it might be overriding.
        static func isConfidentlyOrdered(_ lhs: Order, _ rhs: Order) -> Bool {
            lhs.startedAt != nil && rhs.startedAt != nil
        }

        /// Deterministic, but only trustworthy when both sides carry a timestamp.
        static func isNewer(_ lhs: Order, than rhs: Order) -> Bool {
            if let lhsStarted = lhs.startedAt, let rhsStarted = rhs.startedAt, lhsStarted != rhsStarted {
                return lhsStarted > rhsStarted
            }
            return lhs.operationId > rhs.operationId
        }
    }

    private let orders: [String: Order]
    private let claims: [String: Set<String>]

    init(records: [HostNetworkRecoveryRecord]) {
        var orders: [String: Order] = [:]
        var claims: [String: Set<String>] = [:]
        for record in records {
            orders[record.operationId] = Order(
                startedAt: record.startedAt,
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
        orders[record.operationId] ?? Order(startedAt: record.startedAt, operationId: record.operationId)
    }

    /// True when this record is not provably the newest claimant of everything it would
    /// write. That is the case when a strictly newer record claims its target or one of
    /// its snapshot paths, and also when a competing record cannot be placed in apply
    /// order at all, because then nothing proves this one is the newer of the pair.
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
            guard !(fresh.claims[id] ?? []).isDisjoint(with: mine) else { return false }
            guard id != record.operationId else { return false }
            return Order.isNewer(other, than: order)
                || !Order.isConfidentlyOrdered(other, order)
        }
    }
}
