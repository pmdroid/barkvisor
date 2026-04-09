import Foundation
import GRDB

public struct User: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "users"

    public var id: String
    public var username: String
    public var password: String // empty string = no password set yet (requires setup)
    public var createdAt: String

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let username = Column(CodingKeys.username)
        public static let password = Column(CodingKeys.password)
        public static let createdAt = Column(CodingKeys.createdAt)
    }

    public init(
        id: String,
        username: String,
        password: String,
        createdAt: String,
    ) {
        self.id = id
        self.username = username
        self.password = password
        self.createdAt = createdAt
    }
}
