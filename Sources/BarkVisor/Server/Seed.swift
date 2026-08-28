import BarkVisorCore
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import GRDB
import Vapor

enum Seeder {
    static let defaultRepoURL = HomeCatalogOrigin.githubImagesURL
    static let defaultTemplatesURL = HomeCatalogOrigin.githubTemplatesURL

    /// Shared database pool for onboarding operations (avoids creating multiple pools)
    private nonisolated(unsafe) static var _sharedPool: DatabasePool?
    private static let poolLock = NSLock()

    static func sharedPool() throws -> DatabasePool {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let pool = _sharedPool { return pool }
        let dbPath = Config.dbPath.path
        let appDB = try AppDatabase(path: dbPath)
        try appDB.migrate()
        _sharedPool = appDB.pool
        return appDB.pool
    }

    /// Sets the initial password for a user with no password. Called from the native onboarding UI only.
    static func setupInitialPassword(username: String, password: String) throws {
        guard password.count >= 10 else {
            throw NSError(
                domain: "BarkVisor", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Password must be at least 10 characters"],
            )
        }
        let db = try sharedPool()
        let hash = try Bcrypt.hash(password)
        try db.write { database in
            // Ensure the user row exists (first launch — no server seed yet)
            let existing = try User.filter(User.Columns.username == username).fetchOne(database)
            if existing == nil {
                let existingCount = try User.fetchCount(database)
                let user = User(
                    id: UUID().uuidString,
                    username: username,
                    password: "",
                    createdAt: iso8601.string(from: Date()),
                    role: UserRolePolicy.roleForNewUser(existingUserCount: existingCount).rawValue,
                )
                try user.insert(database)
            } else if let existing, !existing.password.isEmpty {
                throw NSError(
                    domain: "BarkVisor", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Password already set for this user"],
                )
            }

            try database.execute(
                sql:
                "UPDATE users SET password = ? WHERE username = ? AND password = ''",
                arguments: [hash, username],
            )
        }
    }

    /// Syncs all built-in repositories directly. Called from onboarding before server starts.
    /// Reports per-image progress via callback. Returns total image count.
    static func syncBuiltInRepositories(progress: @escaping @Sendable (String) -> Void) async throws
        -> Int {
        let db = try sharedPool()
        let isMember = PairingService.hasPairedReceipt(dataDir: Config.dataDir)
        let syncService = RepositorySyncService(
            dbPool: db,
            lastGood: LastGoodCatalogStore(directory: Config.dataDir),
            memberCatalogFetchDisabled: isMember,
        )
        let repos = try await db.read { database in
            try ImageRepository.filter(Column("isBuiltIn") == true).fetchAll(database)
        }

        var totalImages = 0
        for repo in repos {
            progress("Fetching \(repo.name)...")

            try? await syncService.sync(repositoryID: repo.id)

            let images = try await db.read { database in
                try RepositoryImage.filter(Column("repositoryId") == repo.id).fetchAll(database)
            }
            for (i, image) in images.enumerated() {
                progress("Registering \(image.name)... (\(i + 1)/\(images.count))")
            }
            totalImages += images.count
        }
        return totalImages
    }

    /// Syncs templates from the remote catalog URL. Called from onboarding before server starts.
    /// Returns the number of templates synced.
    static func syncBuiltInTemplates(progress: @escaping @Sendable (String) -> Void) async throws
        -> Int {
        if PairingService.hasPairedReceipt(dataDir: Config.dataDir) {
            progress("Applying Home catalog...")
            let db = try sharedPool()
            let syncService = RepositorySyncService(
                dbPool: db,
                lastGood: LastGoodCatalogStore(directory: Config.dataDir),
                memberCatalogFetchDisabled: true,
            )
            let repos = try await db.read { database in
                try ImageRepository
                    .filter(Column("isBuiltIn") == true)
                    .filter(Column("repoType") == "templates")
                    .fetchAll(database)
            }
            for repo in repos {
                try? await syncService.sync(repositoryID: repo.id)
            }
            return await (try? db.read { try VMTemplate.filter(Column("isBuiltIn") == true).fetchCount($0) })
                ?? 0
        }

        progress("Fetching template catalog...")

        guard let catalog = try await loadTemplateCatalog() else { return 0 }
        let db = try sharedPool()
        let encoder = JSONEncoder()
        let now = iso8601.string(from: Date())

        for (index, entry) in catalog.templates.enumerated() {
            progress("Registering \(entry.name)... (\(index + 1)/\(catalog.templates.count))")

            try await db.write { database in
                // Upsert by slug
                if var existing = try VMTemplate.filter(Column("slug") == entry.slug).fetchOne(
                    database,
                ) {
                    existing.name = entry.name
                    existing.description = entry.description
                    existing.category = entry.category
                    existing.icon = entry.icon
                    existing.imageSlug = entry.imageSlug
                    existing.cpuCount = entry.cpuCount
                    existing.memoryMB = entry.memoryMB
                    existing.diskSizeGB = entry.diskSizeGB
                    existing.portForwards = try String(
                        data: encoder.encode(entry.portForwards), encoding: .utf8,
                    )
                    existing.inputs =
                        try String(
                            data: encoder.encode(entry.inputs), encoding: .utf8,
                        ) ?? "[]"
                    existing.networkMode = entry.networkMode ?? "nat"
                    existing.userDataTemplate = entry.userDataTemplate
                    existing.architecturesJson = JSONColumnCoding.encodeArrayOrNil(entry.architectures)
                    existing.minMemoryMB = entry.minMemoryMB
                    existing.requiredFeaturesJson = JSONColumnCoding.encodeArrayOrNil(
                        entry.requiredFeatures,
                    )
                    existing.imageByArchJson = JSONColumnCoding.encode(entry.imageByArch)
                    existing.updatedAt = now
                    try existing.update(database)
                } else {
                    let template = try VMTemplate(
                        id: UUID().uuidString,
                        slug: entry.slug,
                        name: entry.name,
                        description: entry.description,
                        category: entry.category,
                        icon: entry.icon,
                        imageSlug: entry.imageSlug,
                        cpuCount: entry.cpuCount,
                        memoryMB: entry.memoryMB,
                        diskSizeGB: entry.diskSizeGB,
                        portForwards: String(
                            data: encoder.encode(entry.portForwards), encoding: .utf8,
                        ),
                        networkMode: entry.networkMode ?? "nat",
                        inputs: String(data: encoder.encode(entry.inputs), encoding: .utf8) ?? "[]",
                        userDataTemplate: entry.userDataTemplate,
                        isBuiltIn: true,
                        repositoryId: nil,
                        createdAt: now,
                        updatedAt: now,
                        architecturesJson: JSONColumnCoding.encodeArrayOrNil(entry.architectures),
                        minMemoryMB: entry.minMemoryMB,
                        requiredFeaturesJson: JSONColumnCoding.encodeArrayOrNil(entry.requiredFeatures),
                        imageByArchJson: JSONColumnCoding.encode(entry.imageByArch),
                    )
                    try template.insert(database)
                }
            }
        }

        return catalog.templates.count
    }

    /// Returns the current image and template counts for the onboarding UI.
    static func catalogCounts() -> (images: Int, templates: Int) {
        guard let db = try? sharedPool() else { return (0, 0) }
        let images = (try? db.read { try RepositoryImage.fetchCount($0) }) ?? 0
        let templates =
            (try? db.read { try VMTemplate.filter(Column("isBuiltIn") == true).fetchCount($0) })
                ?? 0
        return (images, templates)
    }

    /// Checks whether the given user already has a password set.
    static func isPasswordSet(username: String) -> Bool {
        guard let db = try? sharedPool() else { return false }
        return
            (try? db.read { database in
                let user = try User.filter(User.Columns.username == username).fetchOne(database)
                return user.map { !$0.password.isEmpty } ?? false
            }) ?? false
    }

    /// Remote catalog first; then the installed share copy; then
    /// `repos/templates.json` walking up from the working directory
    /// (`Server/Resources/templates.json` is unused).
    private static func loadTemplateCatalog() async throws -> TemplateCatalog? {
        if let url = URL(string: defaultTemplatesURL),
           let data = try? await SSRFCatalogURLFetcher().fetch(url: url),
           let catalog = try? JSONDecoder().decode(TemplateCatalog.self, from: data) {
            return catalog
        }
        if let local = localTemplatesCatalogURL(),
           let data = try? Data(contentsOf: local),
           let catalog = try? JSONDecoder().decode(TemplateCatalog.self, from: data) {
            Log.server.info("Loaded template catalog from \(local.path)")
            return catalog
        }
        return nil
    }

    /// Homebrew installs the catalog at `$prefix/share/barkvisor/templates.json`
    /// (`Config.shareDir`). Brew services pin WorkingDirectory to
    /// `/var/lib/barkvisor`, so a cwd walk never reaches the keg copy.
    static func localTemplatesCatalogURL(
        shareDir: String = Config.shareDir,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
    ) -> URL? {
        let fm = FileManager.default
        let shareRoot = URL(fileURLWithPath: shareDir, isDirectory: true)
        let installed = [
            shareRoot.appendingPathComponent("templates.json"),
            shareRoot.appendingPathComponent("repos/templates.json"),
        ]
        for candidate in installed where fm.isReadableFile(atPath: candidate.path) {
            return candidate
        }
        var dir = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        for _ in 0 ..< 8 {
            let candidate = dir.appendingPathComponent("repos/templates.json")
            if fm.isReadableFile(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func seedDefaultNetwork(db: DatabasePool) throws {
        try db.write { database in
            let count = try Network.filter(Column("isDefault") == true).fetchCount(database)
            if count == 0 {
                let network = Network(
                    id: UUID().uuidString,
                    name: "Default NAT",
                    mode: "nat",
                    bridge: nil,
                    macAddress: nil,
                    dnsServer: nil,
                    autoCreated: false,
                    isDefault: true,
                )
                try network.insert(database)
                Log.server.info("Seeded default NAT network")
            }
        }
    }

    static func seedDefaultRepository(db: DatabasePool, isMember: Bool = false) throws {
        try db.write { database in
            let imageRepoCount =
                try ImageRepository
                    .filter(Column("isBuiltIn") == true)
                    .filter(Column("repoType") == "images")
                    .fetchCount(database)
            if imageRepoCount == 0 {
                let now = iso8601.string(from: Date())
                let repo = ImageRepository(
                    id: UUID().uuidString,
                    name: "BarkVisor Official",
                    url: HomeCatalogOrigin.seedURL(repoType: "images", isMember: isMember),
                    isBuiltIn: true,
                    repoType: "images",
                    lastSyncedAt: nil,
                    lastError: nil,
                    syncStatus: "idle",
                    createdAt: now,
                    updatedAt: now,
                )
                try repo.insert(database)
                Log.server.info("Seeded built-in image repository")
            }

            let templateRepoCount =
                try ImageRepository
                    .filter(Column("isBuiltIn") == true)
                    .filter(Column("repoType") == "templates")
                    .fetchCount(database)
            if templateRepoCount == 0 {
                let now = iso8601.string(from: Date())
                let repo = ImageRepository(
                    id: UUID().uuidString,
                    name: "BarkVisor Templates",
                    url: HomeCatalogOrigin.seedURL(repoType: "templates", isMember: isMember),
                    isBuiltIn: true,
                    repoType: "templates",
                    lastSyncedAt: nil,
                    lastError: nil,
                    syncStatus: "idle",
                    createdAt: now,
                    updatedAt: now,
                )
                try repo.insert(database)
                Log.server.info("Seeded built-in templates repository")
            }

            if isMember {
                try HomeCatalogOrigin.flipGitHubBuiltIns(database)
            }
        }
    }
}
