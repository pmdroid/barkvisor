import Foundation

/// Closed runtime state for a VM. Persisted as TEXT on `vms.state`.
public enum VMState: String, Codable, Sendable, CaseIterable {
    case stopped
    case starting
    case running
    case stopping
    case error
    case provisioning
    case deleting

    /// Parse a stored/API value. Unknown strings fail closed to `error`.
    public static func parse(_ raw: String) -> VMState {
        VMState(rawValue: raw) ?? .error
    }
}
