import Foundation
import GRDB

public struct SSHKey: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "ssh_keys"

    public var id: String
    public var name: String
    public var publicKey: String
    public var fingerprint: String
    public var keyType: String
    public var isDefault: Bool
    public var createdAt: String

    public init(
        id: String,
        name: String,
        publicKey: String,
        fingerprint: String,
        keyType: String,
        isDefault: Bool,
        createdAt: String,
    ) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.keyType = keyType
        self.isDefault = isDefault
        self.createdAt = createdAt
    }
}
