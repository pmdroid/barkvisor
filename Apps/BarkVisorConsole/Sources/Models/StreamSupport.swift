import Foundation

/// Serial / VNC stay local to this Device. Member Devices wait for PAS-200.
enum WorkloadStream {
    static func isLive(_ state: String) -> Bool {
        state == "running" || state == "stopping"
    }
}

enum WorkloadStreamAccess: Equatable {
    case available
    case memberDisabled
    case notLive

    static func resolve(isSelfDevice: Bool, state: String) -> WorkloadStreamAccess {
        guard isSelfDevice else { return .memberDisabled }
        return WorkloadStream.isLive(state) ? .available : .notLive
    }

    /// This slice ships empty Console / Display destinations. Member stays closed.
    var allowsOpen: Bool { self == .available }

    var reason: String {
        switch self {
        case .available:
            return ""
        case .memberDisabled:
            return "Console and Display on a member Device are not available yet."
        case .notLive:
            return "The Workload must be running."
        }
    }
}

enum WorkloadGuestSummary {
    static func osLabel(workload: Workload, guest: GuestInfo?) -> String {
        if let os = guest?.osLabel { return os }
        return workload.guestOSFamily
    }

    static func ipLabel(guest: GuestInfo?) -> String? {
        guest?.primaryIP
    }
}

enum GuestInfoRefresh {
    /// Retry only while running and guest-info has not returned a body.
    /// `available: false` (NAT fallback / no agent) is terminal.
    static func shouldRetry(guest: GuestInfo?, running: Bool) -> Bool {
        running && guest == nil
    }
}
