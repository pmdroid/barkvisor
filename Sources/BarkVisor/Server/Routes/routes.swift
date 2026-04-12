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
    let setupMiddleware: SetupMiddleware
    let updateService: UpdateService
}

func registerRoutes(_ app: Vapor.Application, deps: RouteDependencies) throws {
    try app.register(collection: SetupController(setupMiddleware: deps.setupMiddleware, keys: deps.keys))
    try app.register(collection: AuthController(keys: deps.keys, loginRateLimit: deps.loginRateLimit))

    app.get("api", "health") { req in
        do {
            let _: Row? = try req.db.read { db in try Row.fetchOne(db, sql: "SELECT 1") }
            return ["status": "ok"]
        } catch {
            throw Abort(.serviceUnavailable, reason: "Database unreachable")
        }
    }

    let protected = app.grouped(JWTAuthMiddleware(keys: deps.keys))

    try protected.register(collection: ImageController(downloader: deps.imageDownloader))
    try protected.register(
        collection: VMController(
            vmManager: deps.vmManager,
            qmpDiskService: deps.qmpDiskService,
            metricsCollector: deps.metricsCollector,
            stateStreamService: deps.stateStreamService,
            backgroundTasks: deps.backgroundTasks,
        ),
    )

    try AuthController(keys: deps.keys, loginRateLimit: deps.loginRateLimit)
        .bootProtected(routes: protected)

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
            vmManager: deps.vmManager, imageDownloader: deps.imageDownloader,
        ),
    )

    try protected.register(collection: SystemController(imageDownloader: deps.imageDownloader))

    try protected.register(
        collection: UpdateController(
            updateService: deps.updateService, backgroundTasks: deps.backgroundTasks,
        ),
    )

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
}
