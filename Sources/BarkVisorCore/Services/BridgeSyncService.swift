import Foundation
import GRDB

public enum BridgeSyncService {
    public static func syncOnce(db: DatabasePool) async {
        do {
            let states = try await HelperXPCClient.shared.getAllBridgeStates()
            let now = iso8601.string(from: Date())

            try await db.write { db in
                let existing = try BridgeRecord.fetchAll(db)
                let existingByInterface = Dictionary(
                    uniqueKeysWithValues: existing.map { ($0.interface, $0) },
                )
                let reportedInterfaces = Set(states.map(\.interface))

                for state in states {
                    let record = BridgeRecord(
                        id: existingByInterface[state.interface]?.id,
                        interface: state.interface,
                        socketPath: state.socketPath,
                        plistExists: state.plistExists,
                        daemonRunning: state.daemonRunning,
                        status: state.status,
                        updatedAt: now,
                    )
                    try record.save(db, onConflict: .replace)
                }

                // Remove interfaces no longer reported by the helper
                let stale = Set(existingByInterface.keys).subtracting(reportedInterfaces)
                if !stale.isEmpty {
                    try BridgeRecord
                        .filter(stale.contains(Column("interface")))
                        .deleteAll(db)
                }
            }
        } catch {
            Log.server.warning("Bridge sync failed: \(error)")
        }
    }
}
