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
    private(set) var healthProbes: HealthProbeService?
    private(set) var diskInfoCache: DiskInfoCache?
    private(set) var setupMiddleware: SetupMiddleware?
    private(set) var agentTLSServer: AgentTLSServer?

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
        let (libraryDir, disksDir) = try await database.pool.read { db in
            try (
                LibrarySettings.resolvedDirectory(from: db),
                DiskSettings.resolvedDirectory(from: db),
            )
        }
        try Config.ensureDirectories(imagesDir: libraryDir, disksDir: disksDir)
        await LogService.shared.setDatabase(database.pool)

        if let warning = startupWarning {
            await AuditService.logSystem(
                action: "db.recovery.data_loss",
                detail: warning,
                db: database.pool,
            )
        }

        try Seeder.seedDefaultNetwork(db: database.pool)
        try Seeder.seedDefaultRepository(
            db: database.pool,
            isMember: PairingService.hasPairedReceipt(dataDir: Config.dataDir),
        )

        let setup = SetupMiddleware(dbPool: database.pool)
        self.setupMiddleware = setup
        app.middleware.use(setup)

        let services = await createServices(app: app, database: database)
        await services.processMonitor.reconnectOrCleanup()
        await WorkloadAutostart.startEligible(db: database.pool, vmManager: services.manager)

        app.middleware.use(RequestLogMiddleware())

        await runStartupTasks(
            pool: database.pool,
            backgroundTasks: services.backgroundTasks,
            imageDownloader: services.downloader,
            syncService: services.syncService,
        )
        await schedulePeriodicTasks(
            pool: database.pool,
            backgroundTasks: services.backgroundTasks,
            vmManager: services.manager,
            imageDownloader: services.downloader,
            stateStreamService: services.stateStreamService,
            syncService: services.syncService,
        )

        Log.server.info("BarkVisor server starting on port \(Config.port)")

        let loginRateLimit = configureRateLimit(
            backgroundTasks: services.backgroundTasks,
            maxAttempts: RateLimitPolicy.loginMaxAttempts(
                enabled: Config.rateLimitEnabled,
                configured: Config.rateLimitMaxAttempts,
            ),
            pruneTaskID: "rate-limit-prune",
        )
        if !Config.rateLimitEnabled {
            Log.server.info("Login rate limiting is DISABLED via settings")
        }
        let pairingRateLimit = configureRateLimit(
            backgroundTasks: services.backgroundTasks,
            maxAttempts: RateLimitPolicy.pairingMaxAttempts(
                configured: Config.rateLimitMaxAttempts,
            ),
            pruneTaskID: "pairing-rate-limit-prune",
        )
        let pairingOffers = PairingOfferStore(dataDir: Config.dataDir)

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
                pairingRateLimit: pairingRateLimit,
                setupMiddleware: setup,
                healthProbes: services.healthProbes,
                pairingOffers: pairingOffers,
                jwt: JWTAuthMiddleware(keys: keys),
            ),
        )

        Task {
            if PairingService.hasPairedReceipt(dataDir: Config.dataDir) {
                await HomeCatalogFanout.pullMissing()
            }
        }

        try await app.startup()
        self.app = app
        if let bound = app.http.server.shared.localAddress?.port {
            Config.adoptBoundHTTPPort(bound)
        }

        // PAS-76: agent mTLS is best-effort. Local SQLite / QEMU keep running
        // if 7778 cannot bind or cert material cannot be written (PAS-47/90).
        self.agentTLSServer = await AgentTLSServer.startDetached(
            dataDir: Config.dataDir,
            hostId: Config.hostId,
            database: database.pool,
            vmState: services.manager,
            consoleBuffers: services.consoleBuffers,
        )
        if let bound = self.agentTLSServer?.boundPort {
            Config.adoptBoundAgentPort(bound)
        }

        scheduleFirstBootJoin(setupComplete: setup.isSetupComplete)
    }

    /// PAS-180: console-local first-boot join. Best-effort so a down Home
    /// never stops this Device (PAS-47 / PAS-90).
    private func scheduleFirstBootJoin(setupComplete: Bool) {
        let alreadyPaired = FileManager.default.fileExists(
            atPath: PairingService.receiptURL(in: Config.dataDir).path,
        )
        guard let offer = LocalPairingJoin.firstBootOffer(
            environment: ProcessInfo.processInfo.environment,
            setupComplete: setupComplete,
            alreadyPaired: alreadyPaired,
        ) else { return }
        Task {
            do {
                let result = try await LocalPairingJoin.post(
                    offer: offer,
                    client: URLSessionPairingHTTPClient(),
                )
                Log.server.info(
                    "Joined Home via \(LocalPairingJoin.environmentKey) (peer \(result.peerHostId))",
                )
            } catch {
                Log.server.warning(
                    "\(LocalPairingJoin.environmentKey) join failed (Device still running): \(error.localizedDescription)",
                )
            }
        }
    }

    // MARK: - Bootstrap Helpers

    private struct Services {
        let downloader: ImageDownloader
        let syncService: RepositorySyncService
        let collector: MetricsCollector
        let guestAgentInventory: GuestAgentInventory
        let stateStreamService: VMStateStreamService
        let manager: VMManager
        let qmpDiskService: QMPDiskService
        let backgroundTasks: BackgroundTaskManager
        let diskInfoCache: DiskInfoCache
        let consoleBuffers: ConsoleBufferManager
        let processMonitor: VMProcessMonitor
        let healthProbes: HealthProbeService
    }

    private func configureMiddleware(app: Vapor.Application) {
        app.http.server.configuration.hostname = "0.0.0.0"
        app.http.server.configuration.port = Config.port
        app.routes.defaultMaxBodySize = "1mb"

        app.middleware.use(StructuredErrorMiddleware())

        let allowedOrigin: CORSMiddleware.AllowOriginSetting = .all
        let apiVersionHeader = HTTPHeaders.Name(APIContract.versionHeaderName)
        let cors = CORSMiddleware(
            configuration: .init(
                allowedOrigin: allowedOrigin,
                allowedMethods: [.GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS],
                allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith],
                exposedHeaders: [apiVersionHeader, HTTPHeaders.Name("X-Request-Id")],
            ),
        )
        app.middleware.use(cors, at: .beginning)
        // Outermost after CORS so error responses also carry the version header.
        app.middleware.use(APIVersionMiddleware(), at: .beginning)

        let distPath = Config.serveFrontend ? Self.findFrontendDist() : nil
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

                guard DatabaseOpenRecovery.shouldRestoreFromBackup(error) else {
                    Log.server.error(
                        "Leaving the live database in place (not a SQLite corruption): \(error)",
                    )
                    throw error
                }

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

        let lastGood = LastGoodCatalogStore(directory: Config.dataDir)
        let isMember = PairingService.hasPairedReceipt(dataDir: Config.dataDir)
        let publish: (@Sendable (String, Data) async -> Void)? = if isMember {
            nil
        } else {
            { repoType, data in
                await HomeCatalogFanout.publish(repoType: repoType, data: data)
            }
        }
        let syncService = RepositorySyncService(
            dbPool: pool,
            lastGood: lastGood,
            fetcher: SSRFCatalogURLFetcher(),
            memberCatalogFetchDisabled: isMember,
            publish: publish,
        )
        repositorySyncService = syncService

        let collector = MetricsCollector()
        metricsCollector = collector
        let guestAgentInventory = GuestAgentInventory(dbPool: pool)
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

        let consoleBuffers = ConsoleBufferManager()
        await manager.setConsoleBuffers(consoleBuffers)
        await manager.setMetricsCollector(collector)
        await manager.setGuestAgentInventory(guestAgentInventory)
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
        await processMonitor.setGuestAgentInventory(guestAgentInventory)
        await processMonitor.setStateStreamService(stateStreamService)
        await processMonitor.setQMPEventListener(qmpEventListener)
        await manager.setProcessMonitor(processMonitor)

        let healthProbes = HealthProbeService(dbPool: pool)
        self.healthProbes = healthProbes

        return Services(
            downloader: downloader, syncService: syncService, collector: collector,
            guestAgentInventory: guestAgentInventory,
            stateStreamService: stateStreamService, manager: manager,
            qmpDiskService: qmpDiskService, backgroundTasks: backgroundTasks,
            diskInfoCache: diskInfoCache, consoleBuffers: consoleBuffers,
            processMonitor: processMonitor, healthProbes: healthProbes,
        )
    }

    private func runStartupTasks(
        pool: DatabasePool,
        backgroundTasks: BackgroundTaskManager,
        imageDownloader: ImageDownloader,
        syncService: RepositorySyncService,
    ) async {
        await AuditService.pruneOldEntries(db: pool)
        await AuditService.logSystem(action: "app.start", db: pool)
        await LogService.shared.pruneOldLogs()
        LeftoverHelperInventory.warnIfPresent()
        if Config.backupEnabled {
            BackupService.pruneOldBackups()
            BackupService.performBackup(pool: pool)
        }
        await BridgeSyncService.syncOnce(db: pool)
        await HostNetworkPendingReaper.expire(db: pool)
        do {
            try await ImageService.failInterruptedDownloads(db: pool)
        } catch {
            Log.images.error(
                "Failed to mark interrupted image downloads: \(error.localizedDescription)",
            )
        }
        _ = try? await APIKeyService.deleteExpired(db: pool)
        do {
            _ = try await APIKeyService.revokeUnverifiableKeysIfHmacSecretGenerated(
                db: pool, dataDir: Config.dataDir,
            )
        } catch {
            Log.auth.error(
                "Failed to drop unverifiable API keys after HMAC secret split: \(error.localizedDescription)",
            )
        }
        let ollama = OllamaController(backgroundTasks: backgroundTasks)
        let home = HomeOllamaController(backgroundTasks: backgroundTasks, localOllama: ollama)
        _ = try? await home.refresh(db: pool)
        await TemplateDeployService.resumePending(
            imageDownloader: imageDownloader,
            backgroundTasks: backgroundTasks,
            db: pool,
        )
        await BuiltInCatalogSync.submitStartup(
            backgroundTasks: backgroundTasks,
            syncService: syncService,
        )
    }

    private func schedulePeriodicTasks(
        pool: DatabasePool,
        backgroundTasks: BackgroundTaskManager,
        vmManager: VMManager,
        imageDownloader: ImageDownloader,
        stateStreamService: VMStateStreamService,
        syncService: RepositorySyncService,
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
            BackupService.pruneOldBackups()
            BackupService.performBackup(pool: pool)
        }
        // Poll managed bridge daemons (socket_vmnet) only — Linux host bridges are
        // OS-managed (no 5s sysfs forever). Slightly longer than 5s keeps UI fresh
        // without constant wakeups.
        if PlatformCapabilities.supportsManagedBridgeDaemon {
            let bridgeSyncNs: UInt64 = 15 * 1_000_000_000
            await backgroundTasks.schedulePeriodicTask(id: "bridge-sync", interval: bridgeSyncNs) {
                await BridgeSyncService.syncOnce(db: pool)
            }
        }
        await backgroundTasks.schedulePeriodicTask(
            id: "host-network-pending",
            interval: 2 * 1_000_000_000,
        ) {
            await HostNetworkPendingReaper.expire(db: pool)
        }
        if let healthProbes {
            await backgroundTasks.schedulePeriodicTask(
                id: "health-probes", interval: 5 * 1_000_000_000,
            ) {
                await healthProbes.pollDue()
            }
        }
        let ollamaRefreshNs = UInt64(OllamaHomeMap.refreshInterval * 1_000_000_000)
        await backgroundTasks.schedulePeriodicTask(id: "ollama-map", interval: ollamaRefreshNs) {
            let ollama = OllamaController(backgroundTasks: backgroundTasks)
            let home = HomeOllamaController(backgroundTasks: backgroundTasks, localOllama: ollama)
            _ = try? await home.refresh(db: pool)
        }
        await backgroundTasks.schedulePeriodicTask(
            id: "coding-agent-ttl", interval: 30 * 1_000_000_000,
        ) {
            await CodingAgentLifecycleService.tick(now: Date(), vmManager: vmManager, db: pool)
        }
        let pendingProgress = PendingVMProgressTicker()
        await backgroundTasks.schedulePeriodicTask(
            id: "pending-vm-progress", interval: 1_000_000_000,
        ) {
            await pendingProgress.tick(
                db: pool, downloader: imageDownloader, stream: stateStreamService,
            )
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
        await BuiltInCatalogSync.scheduleDaily(
            backgroundTasks: backgroundTasks,
            syncService: syncService,
        )
    }

    private func configureRateLimit(
        backgroundTasks: BackgroundTaskManager,
        maxAttempts: Int,
        pruneTaskID: String,
    ) -> RateLimitMiddleware {
        let store = RateLimitStore(
            maxAttempts: maxAttempts,
            window: TimeInterval(Config.rateLimitWindow),
        )
        Task {
            await backgroundTasks.schedulePeriodicTask(
                id: pruneTaskID, interval: 60 * 60 * 1_000_000_000,
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
        if let agentTLSServer {
            await agentTLSServer.stop()
            self.agentTLSServer = nil
        }
        if let app {
            try? await app.asyncShutdown()
            self.app = nil
        }
    }

    /// Find the frontend dist directory by searching known paths
    private static func findFrontendDist() -> String? {
        // 0. Explicit override for containers / custom layouts
        if let override = ProcessInfo.processInfo.environment["BARKVISOR_FRONTEND_DIR"],
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override + "/index.html") {
            return override
        }

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
