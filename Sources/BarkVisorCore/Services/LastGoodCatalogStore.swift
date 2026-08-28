import Foundation

public struct LastGoodCatalogStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.appendingPathComponent("catalog", isDirectory: true)
    }

    public func fileURL(repoType: String) -> URL {
        directory.appendingPathComponent("\(repoType).json")
    }

    public func load(repoType: String) -> Data? {
        let url = fileURL(repoType: repoType)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func save(repoType: String, data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(repoType: repoType)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path,
        )
    }
}
