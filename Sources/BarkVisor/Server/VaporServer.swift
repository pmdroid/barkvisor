import BarkVisorCore
import Foundation
import GRDB
import JWTKit
import Vapor

public final class VaporServer: @unchecked Sendable {
    private var app: Vapor.Application?
    private let keys: JWTKeyCollection
    private(set) var imageDownloader: ImageDownloader?
    private(set) var vmManager: VMManager?
    private(set) var processMonitor: VMProcessMonitor?
    private(set) var repositorySyncService: RepositorySyncService?
    private(set) var metricsCollector: MetricsCollector?
    private(set) var backgroundTaskManager: BackgroundTaskManager?
    private(set) var diskInfoCache: DiskInfoCache?
    private(set) var setupMiddleware: SetupMiddleware?

    /// Non-nil when the database was recovered in a lossy way at startup.
    /// The UI can check this to display a warning banner to the user.
    private(set) var startupWarning: String?

    public init() {
        self.keys = JWTKeyCollection()
    }

    public func start() async throws {
        // Add HMAC key for signing JWTs
        await keys.add(hmac: .init(from: Config.jwtSecret), digestAlgorithm: .sha256)

        let app = try await Vapor.Application.make(.production)
        do {
            try await bootstrap(app: app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func bootstrap(app: Vapor.Application) async throws {
        configureMiddleware(app: app)

        let database = try openDatabase()
        app.database = database
        await LogService.shared.setDatabase(database.pool)

        if let warning = startupWarning {
            await AuditService.logSystem(
                action: "db.recovery.data_loss",
                detail: warning,
                db: database.pool,
            )
        }

        try Seeder.seedDefaultNetwork(db: database.pool)
        try Seeder.seedDefaultRepository(db: database.pool)

        let setup = SetupMiddleware(dbPool: database.pool)
        self.setupMiddleware = setup
        app.middleware.use(setup)

        let services = await createServices(app: app, database: database)
        await services.processMonitor.reconnectOrCleanup()

        app.middleware.use(RequestLogMiddleware())

        await runStartupTasks(pool: database.pool, backgroundTasks: services.backgroundTasks)
        await schedulePeriodicTasks(pool: database.pool, backgroundTasks: services.backgroundTasks)

        Log.server.info("BarkVisor server starting on port \(Config.port)")

        let loginRateLimit = configureRateLimit(backgroundTasks: services.backgroundTasks)
        let updateService = UpdateService()

        try registerRoutes(
            app,
            deps: RouteDependencies(
                keys: keys,
                imageDownloader: services.downloader,
                vmManager: services.manager,
                consoleBuffers: services.consoleBuffers,
                qmpDiskService: services.qmpDiskService,
                syncService: services.syncService,
                metricsCollector: services.collector,
                stateStreamService: services.stateStreamService,
                backgroundTasks: services.backgroundTasks,
                diskInfoCache: services.diskInfoCache,
                loginRateLimit: loginRateLimit,
                setupMiddleware: setup,
                updateService: updateService,
            ),
        )

        Task {
            let repos = try? await database.pool.read { db in
                try ImageRepository.filter(Column("isBuiltIn") == true).fetchAll(db)
            }
            for repo in repos ?? [] {
                try? await services.syncService.sync(repositoryID: repo.id)
            }
        }

        try await app.startup()
        self.app = app
    }

    // MARK: - Bootstrap Helpers

    private struct Services {
        let downloader: ImageDownloader
        let syncService: RepositorySyncService
        let collector: MetricsCollector
        let stateStreamService: VMStateStreamService
        let manager: VMManager
        let qmpDiskService: QMPDiskService
        let backgroundTasks: BackgroundTaskManager
        let diskInfoCache: DiskInfoCache
        let consoleBuffers: ConsoleBufferManager
        let processMonitor: VMProcessMonitor
    }

    private func configureMiddleware(app: Vapor.Application) {
        app.http.server.configuration.hostname = "0.0.0.0"
        app.http.server.configuration.port = Config.port
        app.routes.defaultMaxBodySize = "1mb"

        app.middleware.use(StructuredErrorMiddleware())

        let allowedOrigin: CORSMiddleware.AllowOriginSetting = .all
        let cors = CORSMiddleware(
            configuration: .init(
                allowedOrigin: allowedOrigin,
                allowedMethods: [.GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS],
                allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith],
            ),
        )
        app.middleware.use(cors, at: .beginning)

        let distPath = Self.findFrontendDist()
        if let distPath {
            app.middleware.use(SPAFallbackMiddleware(indexPath: distPath + "/index.html"))
            app.middleware.use(
                FileMiddleware(
                    publicDirectory: distPath + "/",
                    defaultFile: "index.html",
                ),
            )
        }
    }

    private func openDatabase() throws -> AppDatabase {
        try Config.ensureDirectories()
        do {
            let database = try AppDatabase(path: Config.dbPath.path)
            try database.migrate()
            return database
        } catch {
            Log.server.error("Database failed to open: \(error)")

            let fm = FileManager.default
            let dbPath = Config.dbPath
            let walURL = URL(fileURLWithPath: dbPath.path + "-wal")
            let shmURL = URL(fileURLWithPath: dbPath.path + "-shm")

            do {
                Log.server.info("Retrying database open (preserving WAL)…")
                let database = try AppDatabase(path: dbPath.path)
                try database.migrate()
                Log.server.info("Database opened successfully on retry")
                return database
            } catch {
                Log.server.error("Retry with WAL intact failed: \(error)")

                if let backupName = BackupService.mostRecentBackup() {
                    Log.server.info("Removing WAL/SHM and restoring from backup: \(backupName)")
                    try? fm.removeItem(at: walURL)
                    try? fm.removeItem(at: shmURL)
                    try? fm.removeItem(at: dbPath)
                    try fm.copyItem(
                        at: Config.backupDir.appendingPathComponent(backupName),
                        to: dbPath,
                    )
                    let database = try AppDatabase(path: dbPath.path)
                    try database.migrate()
                    Log.server.info("Database restored from backup: \(backupName)")
                    return database
                } else {
                    Log.server.critical(
                        "No backups available — starting with fresh database. ALL DATA HAS BEEN LOST.",
                    )
                    try? fm.removeItem(at: dbPath)
                    try? fm.removeItem(at: walURL)
                    try? fm.removeItem(at: shmURL)
                    let database = try AppDatabase(path: dbPath.path)
                    try database.migrate()
                    startupWarning =
                        "The database could not be opened and no backups were available. "
                            + "A fresh database was created — all previous data has been lost."
                    return database
                }
            }
        }
    }

    private func createServices(
        app: Vapor.Application, database: AppDatabase,
    ) async -> Services {
        let pool = database.pool
        let downloader = ImageDownloader(dbPool: { pool })
        imageDownloader = downloader

        let syncService = RepositorySyncService(dbPool: pool)
        repositorySyncService = syncService

        let collector = MetricsCollector(dbPool: pool)
        metricsCollector = collector
        await collector.startSystemStatsCollection()

        let stateStreamService = VMStateStreamService()

        let manager = VMManager(dbPool: pool)
        vmManager = manager

        let qmpDiskService = QMPDiskService(vmManager: manager, dbPool: pool)

        let backgroundTasks = BackgroundTaskManager()
        backgroundTaskManager = backgroundTasks

        let diskInfoCache = DiskInfoCache(dbPool: pool)
        self.diskInfoCache = diskInfoCache
        await diskInfoCache.start()

        let consoleBuffers = ConsoleBufferManager(eventLoopGroup: app.eventLoopGroup)
        await manager.setConsoleBuffers(consoleBuffers)
        await manager.setMetricsCollector(collector)
        await manager.setStateStreamService(stateStreamService)

        let qmpEventListener = QMPEventListener(dbPool: pool)
        await qmpEventListener.setVMManager(manager)
        await qmpEventListener.setStateStreamService(stateStreamService)
        await manager.setQMPEventListener(qmpEventListener)

        let processMonitor = VMProcessMonitor(dbPool: pool)
        self.processMonitor = processMonitor
        await processMonitor.setVMManager(manager)
        await processMonitor.setConsoleBuffers(consoleBuffers)
        await processMonitor.setMetricsCollector(collector)
        await processMonitor.setStateStreamService(stateStreamService)
        await processMonitor.setQMPEventListener(qmpEventListener)
        await manager.setProcessMonitor(processMonitor)

        return Services(
            downloader: downloader, syncService: syncService, collector: collector,
            stateStreamService: stateStreamService, manager: manager,
            qmpDiskService: qmpDiskService, backgroundTasks: backgroundTasks,
            diskInfoCache: diskInfoCache, consoleBuffers: consoleBuffers,
            processMonitor: processMonitor,
        )
    }

    private func runStartupTasks(pool: DatabasePool, backgroundTasks: BackgroundTaskManager) async {
        await AuditService.pruneOldEntries(db: pool)
        await AuditService.logSystem(action: "app.start", db: pool)
        await LogService.shared.pruneOldLogs()
        if Config.backupEnabled {
            BackupService.performBackup(pool: pool)
            BackupService.pruneOldBackups()
        }
        await BridgeSyncService.syncOnce(db: pool)
        _ = try? await APIKeyService.deleteExpired(db: pool)
    }

    private func schedulePeriodicTasks(
        pool: DatabasePool, backgroundTasks: BackgroundTaskManager,
    ) async {
        await backgroundTasks.schedulePeriodicTask(
            id: "audit-prune", interval: 24 * 60 * 60 * 1_000_000_000,
        ) {
            await AuditService.pruneOldEntries(db: pool)
        }
        await backgroundTasks.schedulePeriodicTask(
            id: "log-prune", interval: 24 * 60 * 60 * 1_000_000_000,
        ) {
            await LogService.shared.pruneOldLogs()
        }
        await backgroundTasks.schedulePeriodicTask(
            id: "db-backup", interval: 24 * 60 * 60 * 1_000_000_000,
        ) {
            guard Config.backupEnabled else { return }
            BackupService.performBackup(pool: pool)
            BackupService.pruneOldBackups()
        }
        await backgroundTasks.schedulePeriodicTask(id: "bridge-sync", interval: 5 * 1_000_000_000) {
            await BridgeSyncService.syncOnce(db: pool)
        }
        await backgroundTasks.schedulePeriodicTask(
            id: "api-key-expiry", interval: 60 * 60 * 1_000_000_000,
        ) {
            do {
                let count = try await APIKeyService.deleteExpired(db: pool)
                if count > 0 { Log.auth.info("Revoked \(count) expired API key(s)") }
            } catch {
                Log.auth.error("Failed to clean up expired API keys: \(error.localizedDescription)")
            }
        }
    }

    private func configureRateLimit(
        backgroundTasks: BackgroundTaskManager,
    ) -> RateLimitMiddleware {
        let store = RateLimitStore(
            maxAttempts: Config.rateLimitEnabled ? Config.rateLimitMaxAttempts : Int.max,
            window: TimeInterval(Config.rateLimitWindow),
        )
        if !Config.rateLimitEnabled {
            Log.server.info("Login rate limiting is DISABLED via settings")
        }
        Task {
            await backgroundTasks.schedulePeriodicTask(
                id: "rate-limit-prune", interval: 60 * 60 * 1_000_000_000,
            ) {
                await store.prune()
            }
        }
        return RateLimitMiddleware(store: store)
    }

    public func stop() async {
        // Log shutdown before stopping services
        if let app {
            let db = app.database.pool
            let runningCount = await vmManager?.allRunningVMs().count ?? 0
            let detail = runningCount > 0 ? "{\"leftRunning\":\(runningCount)}" : nil
            await AuditService.logSystem(action: "app.stop", detail: detail, db: db)
        }

        // Cancel background tasks and stop disk info cache
        if let backgroundTaskManager {
            await backgroundTaskManager.cancelAll()
        }
        if let diskInfoCache {
            await diskInfoCache.stop()
        }

        // Detach monitoring but leave QEMU processes running
        if let vmManager {
            await vmManager.detachAll()
        }
        if let app {
            try? await app.asyncShutdown()
            self.app = nil
        }
    }

    /// Find the frontend dist directory by searching known paths
    private static func findFrontendDist() -> String? {
        // 1. Installed location
        if FileManager.default.fileExists(atPath: Config.frontendDir + "/index.html") {
            return Config.frontendDir
        }

        // 2. Dev build: walk up from executable to find project root
        var dir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        var projectRoot: URL?
        for _ in 0 ..< 10 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path,
            ) {
                projectRoot = dir
                break
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates: [String] = [
            projectRoot?.appendingPathComponent("Sources/BarkVisor/Resources/frontend/dist").path,
            projectRoot?.appendingPathComponent("frontend/dist").path,
            cwd.appendingPathComponent("Sources/BarkVisor/Resources/frontend/dist").path,
            cwd.appendingPathComponent("frontend/dist").path,
        ].compactMap(\.self)

        for path in candidates where FileManager.default.fileExists(atPath: path + "/index.html") {
            return path
        }
        return nil
    }
}
