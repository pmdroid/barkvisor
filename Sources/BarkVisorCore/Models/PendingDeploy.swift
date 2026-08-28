import Foundation
import GRDB

public struct PendingDeployPayload: Codable, Sendable {
    public var options: DeployOptions
    public var template: VMTemplate
    public var repoImage: RepositoryImage

    public init(options: DeployOptions, template: VMTemplate, repoImage: RepositoryImage) {
        self.options = options
        self.template = template
        self.repoImage = repoImage
    }
}

public struct PendingDeploy: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "pending_deploys"

    public var vmId: String
    public var imageId: String
    public var payload: String
    public var createdAt: String

    public enum Columns {
        public static let vmId = Column(CodingKeys.vmId)
        public static let imageId = Column(CodingKeys.imageId)
    }

    public init(vmId: String, imageId: String, payload: String, createdAt: String) {
        self.vmId = vmId
        self.imageId = imageId
        self.payload = payload
        self.createdAt = createdAt
    }

    public func decodedPayload() throws -> PendingDeployPayload {
        guard let data = payload.data(using: .utf8) else {
            throw BarkVisorError.internalError("Pending deploy payload is not UTF-8")
        }
        return try JSONDecoder().decode(PendingDeployPayload.self, from: data)
    }

    public static func encodePayload(_ value: PendingDeployPayload) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BarkVisorError.internalError("Pending deploy payload is not UTF-8")
        }
        return text
    }
}
