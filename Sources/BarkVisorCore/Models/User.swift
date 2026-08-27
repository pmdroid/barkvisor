import Foundation
import GRDB

public struct User: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "users"

    public var id: String
    public var username: String
    public var password: String // empty string = no password set yet (requires setup)
    public var createdAt: String
    /// `admin` or `inference`. Existing Homes default admin (M012).
    public var role: String

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let username = Column(CodingKeys.username)
        public static let password = Column(CodingKeys.password)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let role = Column(CodingKeys.role)
    }

    public init(
        id: String,
        username: String,
        password: String,
        createdAt: String,
        role: String = UserRole.admin.rawValue,
    ) {
        self.id = id
        self.username = username
        self.password = password
        self.createdAt = createdAt
        self.role = role
    }

    public var userRole: UserRole {
        UserRolePolicy.parseStored(role)
    }

    public var hasPassword: Bool {
        !password.isEmpty
    }

    public static func hasProvisionedAdmin(_ db: Database) throws -> Bool {
        if try User.filter(User.Columns.password != "").fetchCount(db) > 0 {
            return true
        }
        return try PasskeyCredential.fetchCount(db) > 0
    }

    public static func fetchProvisionedAdmin(_ db: Database) throws -> User? {
        if let user = try User.filter(User.Columns.password != "").order(User.Columns.createdAt.asc).fetchOne(db) {
            return user
        }
        guard let passkey = try PasskeyCredential.order(PasskeyCredential.Columns.createdAt.asc).fetchOne(db) else {
            return nil
        }
        return try User.fetchOne(db, key: passkey.userId)
    }
}
