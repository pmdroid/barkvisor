import Foundation
import GRDB

public enum BuiltInCatalogSync {
    public static let startupTaskID = "catalog-sync-startup"
    public static let periodicTaskID = "catalog-sync"
    public static let intervalNanoseconds: UInt64 = 24 * 60 * 60 * 1_000_000_000

    @discardableResult
    public static func submitStartup(
        backgroundTasks: BackgroundTaskManager,
        syncService: RepositorySyncService,
    ) async -> String {
        await backgroundTasks.submit(startupTaskID, kind: .repoSync) {
            await syncService.syncBuiltIns()
            return nil
        }
    }

    public static func scheduleDaily(
        backgroundTasks: BackgroundTaskManager,
        syncService: RepositorySyncService,
    ) async {
        await backgroundTasks.schedulePeriodicTask(
            id: periodicTaskID,
            interval: intervalNanoseconds,
        ) {
            await syncService.syncBuiltIns()
        }
    }
}

extension RepositorySyncService: BuiltInCatalogSyncing {}
