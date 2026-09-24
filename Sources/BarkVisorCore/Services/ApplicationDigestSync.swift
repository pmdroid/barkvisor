import Foundation
import GRDB

public enum ApplicationDigestSync {
    public static let periodicTaskID = "app-digest-sync"
    public static let intervalNanoseconds: UInt64 = 24 * 60 * 60 * 1_000_000_000

    public static func scheduleDaily(
        backgroundTasks: BackgroundTaskManager,
        db: DatabasePool,
        operations: WorkloadOperationCoordinator? = nil,
    ) async {
        await backgroundTasks.schedulePeriodicTask(
            id: periodicTaskID,
            interval: intervalNanoseconds,
        ) {
            await refreshAll(db: db, operations: operations)
        }
    }

    public static func refreshAll(
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
    ) async {
        let apps: [VM]
        do {
            apps = try await db.read { db in
                try VM.filter(Column("kind") == WorkloadSpec.kindApplication).fetchAll(db)
            }
        } catch {
            Log.vm.warning("Application digest list failed: \(error.localizedDescription)")
            return
        }
        for var vm in apps {
            do {
                try await ApplicationLifecycleService.refreshImageFacts(
                    vm: &vm,
                    db: db,
                    dataDir: dataDir,
                    operations: operations,
                )
            } catch {
                Log.vm.warning(
                    "Application \(vm.id) digest check failed: \(error.localizedDescription)",
                    vm: vm.id,
                )
            }
        }
    }
}
