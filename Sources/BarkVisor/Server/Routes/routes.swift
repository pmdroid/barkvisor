import BarkVisorCore
import GRDB
import JWTKit
import Vapor

struct RouteDependencies {
    let keys: JWTKeyCollection
    let imageDownloader: ImageDownloader
    let vmManager: VMManager
    let consoleBuffers: ConsoleBufferManager
    let qmpDiskService: QMPDiskService
    let syncService: RepositorySyncService
    let metricsCollector: MetricsCollector
    let stateStreamService: VMStateStreamService
    let backgroundTasks: BackgroundTaskManager
    let diskInfoCache: DiskInfoCache
    let loginRateLimit: RateLimitMiddleware
    let pairingRateLimit: RateLimitMiddleware
    let setupMiddleware: SetupMiddleware
    let healthProbes: HealthProbeService
    let pairingOffers: PairingOfferStore
    let jwt: JWTAuthMiddleware
}

func registerRoutes(_ app: Vapor.Application, deps: RouteDependencies) throws {
    try app.register(collection: SetupController(setupMiddleware: deps.setupMiddleware, keys: deps.keys))
    try app.register(collection: AuthController(keys: deps.keys, loginRateLimit: deps.loginRateLimit))

    let pairing = PairingController(
        offers: deps.pairingOffers,
        setupMiddleware: deps.setupMiddleware,
        jwt: deps.jwt,
        pairingRateLimit: deps.pairingRateLimit,
        keys: deps.keys,
    )
    try pairing.boot(routes: app)

    registerProcessHealthRoute(app)

    // Public: published contract (PAS-78) + capabilities for setup gating.
    APIContractController.registerPublicRoutes(app)
    SystemCapabilitiesController.registerPublicRoutes(app)

    let protected = app.grouped(JWTAuthMiddleware(keys: deps.keys))

    try protected.register(collection: ImageController(downloader: deps.imageDownloader))
    try protected.register(
        collection: VMController(
            vmManager: deps.vmManager,
            qmpDiskService: deps.qmpDiskService,
            metricsCollector: deps.metricsCollector,
            stateStreamService: deps.stateStreamService,
            backgroundTasks: deps.backgroundTasks,
            healthProbes: deps.healthProbes,
        ),
    )

    try AuthController(keys: deps.keys, loginRateLimit: deps.loginRateLimit)
        .bootProtected(routes: protected)
    try pairing.bootProtected(routes: protected)

    try protected.register(collection: APIKeyController())
    try protected.register(collection: AuditController())
    try protected.register(collection: CloudInitController())
    try protected.register(collection: SSHKeyController())

    try protected.register(
        collection: DiskController(
            vmState: deps.vmManager, qmpDiskService: deps.qmpDiskService,
            diskInfoCache: deps.diskInfoCache,
        ),
    )
    try protected.register(collection: NetworkController())

    try protected.register(
        collection: RepositoryController(
            syncService: deps.syncService, imageDownloader: deps.imageDownloader,
            backgroundTasks: deps.backgroundTasks,
        ),
    )

    try protected.register(
        collection: TemplateController(
            vmManager: deps.vmManager,
            imageDownloader: deps.imageDownloader,
            backgroundTasks: deps.backgroundTasks,
        ),
    )

    try protected.register(
        collection: WorkloadHealthController(
            vmManager: deps.vmManager, healthProbes: deps.healthProbes,
        ),
    )
    try protected.register(collection: WorkloadApplyController(backgroundTasks: deps.backgroundTasks))
    try protected.register(collection: AgentInventoryController())
    try protected.register(
        collection: HomeDevicesController(
            vmManager: deps.vmManager, healthProbes: deps.healthProbes,
        ),
    )
    let ollama = OllamaController(backgroundTasks: deps.backgroundTasks)
    try protected.register(collection: ollama)
    try protected.register(
        collection: HomeOllamaController(
            backgroundTasks: deps.backgroundTasks,
            localOllama: ollama,
            keys: deps.keys,
        ),
    )
    try protected.register(collection: SystemAboutController())
    try protected.register(collection: SystemHostController())
    try protected.register(collection: SystemBridgeController())
    try protected.register(collection: SystemVirtioWinController(imageDownloader: deps.imageDownloader))
    try protected.register(collection: LibrarySettingsController())
    try protected.register(collection: DiskSettingsController())
    try protected.register(collection: RemoteAccessController())

    try protected.register(
        collection: MetricsController(
            vmState: deps.vmManager, metricsCollector: deps.metricsCollector,
        ),
    )

    try protected.register(collection: TaskController(backgroundTasks: deps.backgroundTasks))

    try protected.register(
        collection: LogController(vmState: deps.vmManager, backgroundTasks: deps.backgroundTasks),
    )

    ConsoleController(
        vmState: deps.vmManager, consoleBuffers: deps.consoleBuffers, keys: deps.keys,
    ).register(app: app)
    VNCController(vmState: deps.vmManager, keys: deps.keys).register(app: app)
    // StreamTicketPolicy: Home tunnel spends session=, not Device ticket=.
    HomeConsoleProxyController().register(app: protected)
}

/// Public liveness probe (PAS-79). Database failure is 503; other checks are
/// reported without failing the probe.
func registerProcessHealthRoute(_ app: Vapor.Application) {
    app.get("api", "health") { req -> ProcessHealthStatus in
        let now = iso8601.string(from: Date())
        var checks: [WorkloadHealthCheck] = []
        do {
            let _: Row? = try req.db.read { db in try Row.fetchOne(db, sql: "SELECT 1") }
            checks.append(WorkloadHealthCheck(name: "database", status: .pass, message: "reachable"))
        } catch {
            throw Abort(.serviceUnavailable, reason: "Database unreachable")
        }

        let dataDir = Config.dataDir.path
        if FileManager.default.isWritableFile(atPath: dataDir) {
            checks.append(WorkloadHealthCheck(name: "dataDir", status: .pass, message: dataDir))
        } else {
            checks.append(
                WorkloadHealthCheck(name: "dataDir", status: .fail, message: "not writable: \(dataDir)"),
            )
        }

        let qemuName = "qemu-system-\(PlatformCapabilities.defaultGuestArch)"
        if let qemu = try? BundleResolver.helper(qemuName) {
            checks.append(WorkloadHealthCheck(name: "qemu", status: .pass, message: qemu.path))
        } else {
            checks.append(
                WorkloadHealthCheck(name: "qemu", status: .skip, message: "\(qemuName) not found"),
            )
        }

        return WorkloadHealthProjector.processHealth(checks: checks, updatedAt: now)
    }
}
