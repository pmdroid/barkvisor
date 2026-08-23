import Foundation
import GRDB

/// PAS-258: start opted-in Workloads after a Device boot, not a daemon restart.
///
/// House appliances stay stopped unless `startOnBoot` is on. Start goes through
/// `VMManager.start`, so Agent-class cage rules still apply.
public enum WorkloadAutostart {
    public static let bootIDKey = "device.last_boot_id"

    public struct Plan: Equatable, Sendable {
        public var isDeviceBoot: Bool
        public var vmIDs: [String]
        public var bootID: String

        public init(isDeviceBoot: Bool, vmIDs: [String], bootID: String) {
            self.isDeviceBoot = isDeviceBoot
            self.vmIDs = vmIDs
            self.bootID = bootID
        }
    }

    public static func plan(
        db: Database,
        bootID: String,
        alreadyRunningIDs: Set<String>,
    ) throws -> Plan {
        let previous = try AppSetting.fetchOne(db, key: bootIDKey)?.value
        let isDeviceBoot = previous != bootID
        guard isDeviceBoot else {
            return Plan(isDeviceBoot: false, vmIDs: [], bootID: bootID)
        }
        let rows = try VM.filter(Column("startOnBoot") == true).fetchAll(db)
        let ids = rows.compactMap { vm -> String? in
            if alreadyRunningIDs.contains(vm.id) { return nil }
            if vm.state == "stopped" || vm.state == "error" { return vm.id }
            return nil
        }
        return Plan(isDeviceBoot: true, vmIDs: ids, bootID: bootID)
    }

    public static func recordBootID(_ bootID: String, db: Database) throws {
        try AppSetting(key: bootIDKey, value: bootID).save(db, onConflict: .replace)
    }

    /// Reconnect QEMU first, then call this. Failures on one Workload do not block others.
    public static func startEligible(db: DatabasePool, vmManager: VMManager) async {
        guard let bootID = DeviceBootIdentity.current() else {
            Log.vm.warning("Device boot id unavailable; skipping autostart")
            return
        }
        let running = await Set((vmManager.allRunningVMs()).keys)
        let plan: Plan
        do {
            plan = try await db.write { db in
                let next = try Self.plan(db: db, bootID: bootID, alreadyRunningIDs: running)
                try Self.recordBootID(bootID, db: db)
                return next
            }
        } catch {
            Log.vm.warning("Autostart plan failed: \(error.localizedDescription)")
            return
        }
        guard plan.isDeviceBoot else { return }
        for vmID in plan.vmIDs {
            do {
                try await vmManager.start(vmID: vmID)
                Log.vm.info("Autostarted Workload \(vmID) after Device boot", vm: vmID)
            } catch {
                Log.vm.warning(
                    "Autostart failed for Workload \(vmID): \(error.localizedDescription)",
                    vm: vmID,
                )
            }
        }
    }
}
