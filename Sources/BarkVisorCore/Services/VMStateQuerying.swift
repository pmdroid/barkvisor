import Foundation

/// Protocol for read-only VM state queries. Controllers that only need to check
/// if a VM is running or get socket paths should depend on this instead of VMManager.
public protocol VMStateQuerying: Sendable {
    func isRunning(_ vmID: String) async -> Bool
    func isActiveOrStarting(_ vmID: String) async -> Bool
    func allRunningVMs() async -> [String: RunningVM]
    func vncSocketPath(for vmID: String) async -> String?
    func serialSocketPath(for vmID: String) async -> String?
    func qmpSocketPath(for vmID: String) async -> String?
}
