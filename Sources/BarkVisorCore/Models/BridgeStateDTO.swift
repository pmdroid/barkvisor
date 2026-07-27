import Foundation

/// Snapshot of a bridged network daemon state (macOS helper; portable DTO for API/sync).
public struct BridgeStateDTO: Codable, Sendable {
    public let interface: String
    public let socketPath: String?
    public let plistExists: Bool
    public let daemonRunning: Bool
    public let status: String

    public init(
        interface: String,
        socketPath: String?,
        plistExists: Bool,
        daemonRunning: Bool,
        status: String,
    ) {
        self.interface = interface
        self.socketPath = socketPath
        self.plistExists = plistExists
        self.daemonRunning = daemonRunning
        self.status = status
    }
}
