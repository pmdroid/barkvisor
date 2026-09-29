import Foundation

public struct DaemonAPIPaths: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var privateDirectory: URL {
        directory.appendingPathComponent("private", isDirectory: true)
    }
    public var http: String {
        directory.appendingPathComponent("http.sock").path
    }
    public var agent: String {
        directory.appendingPathComponent("agent.sock").path
    }
    public var privateHTTP: String {
        privateDirectory.appendingPathComponent("http.sock").path
    }
    public var privateAgent: String {
        privateDirectory.appendingPathComponent("agent.sock").path
    }
}
