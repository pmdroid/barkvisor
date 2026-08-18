import Foundation

/// Using a Workload (start/stop, serial, VNC) is the same on This Device and
/// a reachable member. Create VM is not part of this surface.
enum WorkloadStream {
    static func isLive(_ state: String) -> Bool {
        state == "running" || state == "stopping"
    }

    /// SwiftUI `.task` identity. Running and stopping share one session so ACPI
    /// shutdown does not mint a new ticket or reconnect. Reachability is part of
    /// the id so a member going down stops the session.
    static func sessionTaskID(
        deviceID: String,
        workloadID: String,
        state: String,
        deviceReachable: Bool = true,
    ) -> String {
        let open = isLive(state) && deviceReachable
        return "\(deviceID)/\(workloadID)/\(open ? "live" : "down")"
    }
}

enum WorkloadStreamAccess: Equatable {
    case available
    case deviceUnreachable
    case notLive

    static func resolve(
        isSelfDevice: Bool,
        deviceReachable: Bool,
        state: String,
    ) -> WorkloadStreamAccess {
        if !isSelfDevice, !deviceReachable { return .deviceUnreachable }
        return WorkloadStream.isLive(state) ? .available : .notLive
    }

    static func resolve(device: HomeDeviceHealthSnapshot, state: String) -> WorkloadStreamAccess {
        resolve(isSelfDevice: device.isSelf, deviceReachable: device.isReachable, state: state)
    }

    /// Console / Display while the Workload is live on This Device or a reachable member.
    var allowsOpen: Bool {
        self == .available
    }

    var reason: String {
        switch self {
        case .available:
            return ""
        case .deviceUnreachable:
            return "That Device is unreachable."
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
    /// Retry only while running on a reachable Device and guest-info has not returned a body.
    /// `available: false` (NAT fallback / no agent) is terminal.
    static func shouldRetry(guest: GuestInfo?, running: Bool, reachable: Bool = true) -> Bool {
        reachable && running && guest == nil
    }
}

enum StreamReconnect {
    static let maxAttempts = 10
    static let initialDelayNanoseconds: UInt64 = 1_000_000_000
    static let maxDelayNanoseconds: UInt64 = 30_000_000_000
    /// Bound for a VNC "connecting" wait so a missed startVNC/disconnect can retry.
    static let connectTimeoutNanoseconds: UInt64 = 15_000_000_000

    static func shouldRetry(attempt: Int) -> Bool {
        attempt >= 1 && attempt <= maxAttempts
    }

    /// `attempt` is 1-based (first retry after a disconnect).
    static func delayNanoseconds(attempt: Int) -> UInt64 {
        let shift = max(0, attempt - 1)
        let factor: UInt64 = shift >= 63 ? .max : 1 << shift
        let delay = initialDelayNanoseconds &* factor
        return min(delay == 0 ? .max : delay, maxDelayNanoseconds)
    }
}

enum StreamURL {
    static func console(
        base: URL,
        workloadID: String,
        ticket: String,
        device: HomeDeviceHealthSnapshot? = nil,
        session: String? = nil,
    ) throws -> URL {
        try websocket(
            base: base,
            path: path(kind: "console", workloadID: workloadID, device: device),
            ticket: ticket,
            session: session,
        )
    }

    static func vnc(
        base: URL,
        workloadID: String,
        ticket: String,
        device: HomeDeviceHealthSnapshot? = nil,
        session: String? = nil,
    ) throws -> URL {
        try websocket(
            base: base,
            path: path(kind: "vnc", workloadID: workloadID, device: device),
            ticket: ticket,
            session: session,
        )
    }

    /// Same mapping as the SPA: self `/api/vms/:id/{kind}`, member Home tunnel.
    static func path(
        kind: String,
        workloadID: String,
        device: HomeDeviceHealthSnapshot?,
    ) -> String {
        if let device, !device.isSelf {
            let host = device.hostId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? device.hostId
            let vm = workloadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? workloadID
            return "/api/home/devices/\(host)/v1/vms/\(vm)/\(kind)"
        }
        return "/api/vms/\(workloadID)/\(kind)"
    }

    static func websocket(
        base: URL,
        path: String,
        ticket: String,
        session: String? = nil,
    ) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw APIError.invalidURL
        }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let trimmed = path.hasPrefix("/") ? path : "/\(path)"
        components.path = prefix + trimmed
        var items = [URLQueryItem(name: "ticket", value: ticket)]
        if let session, !session.isEmpty {
            items.append(URLQueryItem(name: "session", value: session))
        }
        components.queryItems = items
        components.fragment = nil
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    /// Used by tests to assert a JWT never appears in a stream URL.
    static func containsSecret(_ url: URL, secret: String) -> Bool {
        guard !secret.isEmpty else { return false }
        return url.absoluteString.contains(secret)
    }
}

struct WSTicketRequest: Encodable {
    var vmID: String
}

struct WSTicketResponse: Decodable {
    var ticket: String
}
