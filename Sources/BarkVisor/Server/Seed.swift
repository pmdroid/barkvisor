import BarkVisorCore
import Foundation
import GRDB
import Vapor

enum Seeder {
    static let defaultRepoURL =
        "https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/images.json"

    static let defaultTemplatesURL =
        "https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/templates.json"

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
                let user = User(
                    id: UUID().uuidString,
                    username: username,
                    password: "",
                    createdAt: iso8601.string(from: Date()),
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
        let syncService = RepositorySyncService(dbPool: db)
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
        progress("Fetching template catalog...")

        guard let url = URL(string: defaultTemplatesURL) else { return 0 }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            return 0
        }

        let catalog = try JSONDecoder().decode(TemplateCatalog.self, from: data)
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

    static func seedDefaultRepository(db: DatabasePool) throws {
        try db.write { database in
            // Seed built-in images repo
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
                    url: defaultRepoURL,
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

            // Seed built-in templates repo
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
                    url: defaultTemplatesURL,
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
        }
    }
}
