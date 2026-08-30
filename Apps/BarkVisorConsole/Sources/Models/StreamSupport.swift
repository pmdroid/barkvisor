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

/// Home / Workloads list power actions. Force Stop stays on Workload detail.
enum WorkloadListAction: String, Equatable, Hashable {
    case start
    case acpiStop

    var title: String {
        switch self {
        case .start: "Start"
        case .acpiStop: "Stop"
        }
    }
}

enum WorkloadListActions {
    /// Start and ACPI Stop only. Hidden when the Device is unreachable or a start/stop is in flight.
    static func resolve(
        canStart: Bool,
        canStop: Bool,
        deviceReachable: Bool,
        inFlight: Bool,
    ) -> [WorkloadListAction] {
        guard deviceReachable, !inFlight else { return [] }
        var actions: [WorkloadListAction] = []
        if canStart { actions.append(.start) }
        if canStop { actions.append(.acpiStop) }
        return actions
    }

    static func resolve(
        workload: Workload,
        deviceReachable: Bool,
        inFlight: Bool,
    ) -> [WorkloadListAction] {
        resolve(
            canStart: workload.canStart,
            canStop: workload.canStop,
            deviceReachable: deviceReachable,
            inFlight: inFlight,
        )
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

    static func macLabel(workload: Workload, guest: GuestInfo?) -> String? {
        let raw = workload.macAddress ?? guest?.macAddress
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func addressingSummary(networkMode: String?) -> String {
        networkMode == "bridged" ? "DHCP (LAN)" : "NAT"
    }

    static func macGuidance(bridged: Bool) -> String {
        if bridged {
            return "Paste this MAC into your router for a DHCP reservation."
        }
        return "Set the address in the guest or on the router. BarkVisor did not configure the OS."
    }
}

enum GuestInfoRefresh {
    /// Retry only while running on a reachable Device and guest-info has not returned a body.
    /// `available: false` (NAT fallback / no agent) is terminal.
    static func shouldRetry(guest: GuestInfo?, running: Bool, reachable: Bool = true) -> Bool {
        reachable && running && guest == nil
    }

    /// Keep polling while running so listening ports can appear after the first snapshot.
    static func pollIntervalSeconds(guest: GuestInfo?, running: Bool, reachable: Bool = true) -> Double? {
        guard reachable, running else { return nil }
        return shouldRetry(guest: guest, running: running, reachable: reachable) ? 5 : 30
    }

    /// SwiftUI `.task` identity. Reachability is part of the id so a member
    /// going down stops polling and recovery starts it again. Busy is part of
    /// the id so ACPI restart cancels a leftover 30s sleep — POST /restart
    /// returns with the Workload running, so `state` often does not change.
    static func taskID(
        deviceID: String,
        workloadID: String,
        state: String,
        reachable: Bool,
        busy: Bool = false,
    ) -> String {
        "\(deviceID)/\(workloadID)/\(state)/\(reachable ? "up" : "down")/\(busy ? "busy" : "idle")"
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

/// Stream credential transport. Policy lives in BarkVisorCore `StreamTicketPolicy`.
enum StreamTickets {
    static let ticketQueryName = "ticket"
    static let sessionQueryName = "session"

    static func needsHomeSession(_ device: HomeDeviceHealthSnapshot?) -> Bool {
        guard let device else { return false }
        return !device.isSelf
    }

    static func queryItems(ticket: String, session: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: ticketQueryName, value: ticket)]
        if let session, !session.isEmpty {
            items.append(URLQueryItem(name: sessionQueryName, value: session))
        }
        return items
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
        components.queryItems = StreamTickets.queryItems(ticket: ticket, session: session)
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
