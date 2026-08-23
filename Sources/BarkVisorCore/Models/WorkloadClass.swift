import Foundation

/// Create-time Workload class (PAS-268). Omitted values are `house`.
///
/// House is the appliance form (LAN, USB). Agent is a cage: NAT out to the WAN,
/// no house LAN, no USB, no daemon port.
public enum WorkloadClass: String, Codable, Sendable, CaseIterable {
    case house
    case agent

    /// Shown on the Workload tile / create form.
    public var grantCopy: String {
        switch self {
        case .house:
            return "House: LAN and USB allowed."
        case .agent:
            return "WAN yes, house no."
        }
    }

    public var label: String {
        switch self {
        case .house: return "House"
        case .agent: return "Agent"
        }
    }

    /// Empty / omitted → house. Unknown strings are 400.
    public static func parse(_ raw: String?) throws -> WorkloadClass {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return .house }
        guard let value = WorkloadClass(rawValue: trimmed) else {
            throw BarkVisorError.badRequest("workloadClass must be 'house' or 'agent'")
        }
        return value
    }
}
