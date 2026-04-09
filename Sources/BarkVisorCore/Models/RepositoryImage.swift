import Foundation
import GRDB

public struct RepositoryImage: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "repository_images"

    public var id: String
    public var repositoryId: String
    public var slug: String
    public var name: String
    public var description: String?
    public var imageType: String
    public var arch: String
    public var version: String?
    public var downloadUrl: String
    public var sizeBytes: Int64?
    public var sha256: String?
    public var sha512: String?

    public init(
        id: String,
        repositoryId: String,
        slug: String,
        name: String,
        description: String?,
        imageType: String,
        arch: String,
        version: String?,
        downloadUrl: String,
        sizeBytes: Int64?,
        sha256: String? = nil,
        sha512: String? = nil,
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.slug = slug
        self.name = name
        self.description = description
        self.imageType = imageType
        self.arch = arch
        self.version = version
        self.downloadUrl = downloadUrl
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.sha512 = sha512
    }
}
