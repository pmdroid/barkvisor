import GRDB

public struct M001_CreateSchema: DatabaseMigration {
    public static let identifier = "M001_CreateSchema"

    public static func migrate(_ db: GRDB.Database) throws {
        try createCoreTables(db)
        try createVMTables(db)
        try createRepositoryTables(db)
        try createAuditAndLogTables(db)
    }

    private static func createCoreTables(_ db: GRDB.Database) throws {
        try db.create(table: "users") { t in
            t.primaryKey("id", .text)
            t.column("username", .text).notNull().unique()
            t.column("password", .text).notNull()
            t.column("createdAt", .text).notNull()
        }

        try db.create(table: "images") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("imageType", .text).notNull()
            t.column("arch", .text).notNull()
            t.column("path", .text).unique()
            t.column("sizeBytes", .integer)
            t.column("status", .text).notNull()
            t.column("error", .text)
            t.column("sourceUrl", .text)
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
        }

        try db.create(table: "networks") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull().unique()
            t.column("mode", .text).notNull()
            t.column("bridge", .text)
            t.column("macAddress", .text)
            t.column("dnsServer", .text)
            t.column("autoCreated", .boolean).notNull().defaults(to: false)
            t.column("isDefault", .boolean).notNull().defaults(to: false)
        }

        try db.create(table: "app_settings") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
        }

        try db.create(table: "bridges") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("interface", .text).notNull().unique()
            t.column("socketPath", .text)
            t.column("plistExists", .boolean).notNull().defaults(to: false)
            t.column("daemonRunning", .boolean).notNull().defaults(to: false)
            t.column("status", .text).notNull().defaults(to: "not_configured")
            t.column("updatedAt", .text).notNull()
        }

        try db.create(table: "ssh_keys") { t in
            t.primaryKey("id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("publicKey", .text).notNull().unique()
            t.column("fingerprint", .text).notNull()
            t.column("keyType", .text).notNull()
            t.column("isDefault", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .text).notNull()
        }

        try db.create(table: "image_repositories") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("url", .text).notNull().unique()
            t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
            t.column("repoType", .text).notNull().defaults(to: "images")
            t.column("lastSyncedAt", .text)
            t.column("lastError", .text)
            t.column("syncStatus", .text).notNull().defaults(to: "idle")
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
        }
        try db.create(
            index: "idx_image_repositories_syncStatus", on: "image_repositories", columns: ["syncStatus"],
        )

        try db.create(table: "tus_uploads") { t in
            t.primaryKey("id", .text)
            t.column("imageId", .text).notNull().references("images", onDelete: .cascade)
            t.column("offset", .integer).notNull().defaults(to: 0)
            t.column("length", .integer).notNull()
            t.column("metadata", .text).notNull()
            t.column("chunkPath", .text).notNull()
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
        }
        try db.create(index: "idx_tus_uploads_imageId", on: "tus_uploads", columns: ["imageId"])
    }

    private static func createVMTables(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE disks (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    sizeBytes INTEGER NOT NULL,
                    format TEXT NOT NULL,
                    vmId TEXT,
                    autoCreated INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'ready' CHECK(status IN ('ready', 'creating', 'downloading')),
                    createdAt TEXT NOT NULL
                )
            """,
        )
        try db.create(index: "idx_disks_vmId", on: "disks", columns: ["vmId"])
        try db.create(index: "idx_disks_status", on: "disks", columns: ["status"])

        try db.execute(
            sql: """
                CREATE TABLE vms (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    vmType TEXT NOT NULL,
                    state TEXT NOT NULL,
                    cpuCount INTEGER NOT NULL,
                    memoryMb INTEGER NOT NULL,
                    bootDiskId TEXT NOT NULL REFERENCES disks(id) ON DELETE CASCADE,
                    isoId TEXT REFERENCES images(id) ON DELETE SET NULL,
                    networkId TEXT REFERENCES networks(id) ON DELETE SET NULL,
                    cloudInitPath TEXT,
                    vncPort INTEGER,
                    description TEXT,
                    bootOrder TEXT DEFAULT 'cd',
                    displayResolution TEXT DEFAULT '1280x800',
                    additionalDiskIds TEXT,
                    uefi INTEGER DEFAULT 1,
                    macAddress TEXT,
                    tpmEnabled INTEGER DEFAULT 0,
                    autoCreated INTEGER NOT NULL DEFAULT 0,
                    sharedPaths TEXT,
                    portForwards TEXT,
                    pendingChanges INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    isoIds TEXT,
                    usbDevices TEXT
                )
            """,
        )
        try db.create(index: "idx_vms_networkId", on: "vms", columns: ["networkId"])

        try db.execute(
            sql: """
                CREATE TABLE guest_info (
                    vmId TEXT PRIMARY KEY NOT NULL REFERENCES vms(id) ON DELETE CASCADE,
                    hostname TEXT,
                    osName TEXT,
                    osVersion TEXT,
                    osId TEXT,
                    kernelVersion TEXT,
                    kernelRelease TEXT,
                    machine TEXT,
                    timezone TEXT,
                    timezoneOffset INTEGER,
                    ipAddresses TEXT,
                    macAddress TEXT,
                    users TEXT,
                    filesystems TEXT,
                    updatedAt TEXT NOT NULL
                )
            """,
        )
    }

    private static func createRepositoryTables(_ db: GRDB.Database) throws {
        try db.create(table: "repository_images") { t in
            t.primaryKey("id", .text)
            t.column("repositoryId", .text).notNull().references("image_repositories", onDelete: .cascade)
            t.column("slug", .text).notNull()
            t.column("name", .text).notNull()
            t.column("description", .text)
            t.column("imageType", .text).notNull()
            t.column("arch", .text).notNull()
            t.column("version", .text)
            t.column("downloadUrl", .text).notNull()
            t.column("sizeBytes", .integer)
            t.column("sha256", .text)
            t.column("sha512", .text)
            t.uniqueKey(["repositoryId", "slug"])
        }
        try db.create(
            index: "idx_repository_images_repositoryId", on: "repository_images",
            columns: ["repositoryId"],
        )

        try db.execute(
            sql: """
                CREATE TABLE vm_templates (
                    id TEXT PRIMARY KEY,
                    slug TEXT NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    category TEXT NOT NULL,
                    icon TEXT NOT NULL,
                    imageSlug TEXT NOT NULL,
                    cpuCount INTEGER NOT NULL,
                    memoryMB INTEGER NOT NULL,
                    diskSizeGB INTEGER NOT NULL,
                    portForwards TEXT,
                    networkMode TEXT DEFAULT 'nat',
                    inputs TEXT NOT NULL,
                    userDataTemplate TEXT NOT NULL,
                    isBuiltIn BOOLEAN NOT NULL DEFAULT 1,
                    repositoryId TEXT REFERENCES image_repositories(id) ON DELETE SET NULL,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    UNIQUE(repositoryId, slug)
                )
            """,
        )

        try db.create(table: "api_keys") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("keyHash", .text).notNull()
            t.column("keyPrefix", .text).notNull()
            t.column("userId", .text).notNull().references("users", onDelete: .cascade)
            t.column("expiresAt", .text)
            t.column("lastUsedAt", .text)
            t.column("createdAt", .text).notNull()
        }
        try db.create(index: "idx_api_keys_userId", on: "api_keys", columns: ["userId"])
    }

    private static func createAuditAndLogTables(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE audit_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp TEXT NOT NULL,
                    userId TEXT REFERENCES users(id) ON DELETE SET NULL,
                    username TEXT,
                    action TEXT NOT NULL,
                    resourceType TEXT,
                    resourceId TEXT,
                    resourceName TEXT,
                    detail TEXT,
                    authMethod TEXT,
                    apiKeyId TEXT REFERENCES api_keys(id) ON DELETE SET NULL
                )
            """,
        )
        try db.create(index: "idx_audit_log_timestamp", on: "audit_log", columns: ["timestamp"])
        try db.create(index: "idx_audit_log_action", on: "audit_log", columns: ["action"])

        try db.create(table: "logs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("ts", .text).notNull()
            t.column("level", .text).notNull()
            t.column("cat", .text).notNull()
            t.column("msg", .text).notNull()
            t.column("vm", .text)
            t.column("req", .text)
            t.column("err", .text)
            t.column("detail", .text)
        }
        try db.create(index: "idx_logs_ts", on: "logs", columns: ["ts"])
        try db.create(index: "idx_logs_level", on: "logs", columns: ["level"])
        try db.create(index: "idx_logs_cat", on: "logs", columns: ["cat"])
        try db.create(index: "idx_logs_vm", on: "logs", columns: ["vm"])
    }
}
