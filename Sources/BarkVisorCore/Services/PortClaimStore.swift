import Foundation
import GRDB

public struct PortReservation: Equatable, Sendable {
    public var operationId: String
    public var workloadKind: String
    public var workloadId: String
    public var publication: PortPublication

    public init(
        operationId: String,
        workloadKind: String,
        workloadId: String,
        publication: PortPublication,
    ) {
        self.operationId = operationId
        self.workloadKind = workloadKind
        self.workloadId = workloadId
        self.publication = publication
    }
}

public enum PortClaimStore {
    public static func claim(
        _ reservations: [PortReservation],
        operationId: String,
        workloadId: String,
        db: Database,
    ) throws {
        guard reservations.allSatisfy({ $0.operationId == operationId && $0.workloadId == workloadId }) else {
            throw BarkVisorError.badRequest("A port claim belongs to one operation and one Workload")
        }
        if db.isInsideTransaction {
            try insertClaim(reservations, operationId: operationId, workloadId: workloadId, db: db)
            return
        }
        try db.inTransaction {
            try insertClaim(reservations, operationId: operationId, workloadId: workloadId, db: db)
            return .commit
        }
    }

    private static func insertClaim(
        _ reservations: [PortReservation],
        operationId: String,
        workloadId: String,
        db: Database,
    ) throws {
            let others = try listed(db: db).filter {
                !($0.operationId == operationId && $0.workloadId == workloadId)
            }
            let configured = try PortRegistry.claims(db: db, excludingVM: workloadId)
            for (index, reservation) in reservations.enumerated() {
                for earlier in reservations.prefix(index) {
                    if NetworkIntentBinding.overlaps(earlier.publication, reservation.publication) {
                        throw BarkVisorError.portInUse(
                            "Host port \(reservation.publication.publishedPort)/\(reservation.publication.proto) "
                                + "is claimed more than once by this operation",
                        )
                    }
                }
                if let owner = others.first(where: {
                    NetworkIntentBinding.overlaps($0.publication, reservation.publication)
                }) {
                    throw BarkVisorError.portInUse(
                        "Host port \(reservation.publication.publishedPort)/\(reservation.publication.proto) "
                            + "is already claimed by \(owner.workloadKind) \(owner.workloadId)",
                    )
                }
                if let configuredOwner = configured.first(where: { claim in
                    let publication = try? NetworkIntent.publication(
                        bindAddress: claim.bindAddress,
                        proto: claim.proto,
                        publishedPort: claim.hostPort,
                        targetPort: claim.hostPort,
                    )
                    guard let publication else { return false }
                    return NetworkIntentBinding.overlaps(publication, reservation.publication)
                }) {
                    throw BarkVisorError.portInUse(
                        "Host port \(reservation.publication.publishedPort)/\(reservation.publication.proto) "
                            + "is already claimed by \(configuredOwner.workloadKind) \"\(configuredOwner.workloadName)\"",
                    )
                }
            }
            try db.execute(
                sql: "DELETE FROM port_claims WHERE operation_id = ? AND workload_id = ?",
                arguments: [operationId, workloadId],
            )
            for reservation in reservations {
                try db.execute(
                    sql: """
                    INSERT INTO port_claims (
                      operation_id, workload_kind, workload_id, host_port, proto, family, bind_address, exposure
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        reservation.operationId,
                        reservation.workloadKind,
                        reservation.workloadId,
                        reservation.publication.publishedPort,
                        reservation.publication.proto,
                        reservation.publication.family.rawValue,
                        reservation.publication.bindAddress,
                        reservation.publication.exposure.rawValue,
                    ],
                )
            }
    }

    @discardableResult
    public static func release(operationId: String, workloadId: String, db: Database) throws -> Int {
        try db.execute(
            sql: "DELETE FROM port_claims WHERE operation_id = ? AND workload_id = ?",
            arguments: [operationId, workloadId],
        )
        return db.changesCount
    }

    public static func listed(db: Database) throws -> [PortReservation] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT operation_id, workload_kind, workload_id, host_port, proto, family, bind_address, exposure
        FROM port_claims
        """)
        return rows.map { row in
            let family = IPFamily(rawValue: row["family"]) ?? .ipv4
            let exposure = PortExposure(rawValue: row["exposure"]) ?? .wildcard
            return PortReservation(
                operationId: row["operation_id"],
                workloadKind: row["workload_kind"],
                workloadId: row["workload_id"],
                publication: PortPublication(
                    family: family,
                    bindAddress: row["bind_address"],
                    proto: row["proto"],
                    publishedPort: row["host_port"],
                    targetPort: row["host_port"],
                    exposure: exposure,
                ),
            )
        }
    }
}
