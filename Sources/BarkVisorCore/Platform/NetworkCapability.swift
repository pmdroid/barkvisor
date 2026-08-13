import Foundation

/// Closed Wave 0 network modes. `tailnet` / `none` are explicitly deferred (PAS-89).
///
/// Product copy maps onto these API values — it is **not** a fourth mode:
/// - `isolated` → Private
/// - `bridged` → Home Network
/// - `nat` → NAT (internet via the host). “Published Service” is NAT **plus**
///   VM port forwards, not a mode of its own.
///
/// A missing `networkId` is **implicit NAT** (`user` slirp). Documented, not
/// treated as an error — clients may omit the network instead of requiring
/// a selection.
public enum NetworkMode: String, Codable, Sendable, CaseIterable {
    case nat
    case bridged
    case isolated

    /// UI / capabilities label. Mode strings stay `nat|bridged|isolated`.
    public var label: String {
        switch self {
        case .nat: return "NAT"
        case .bridged: return "Bridged (Home Network)"
        case .isolated: return "Isolated (Private)"
        }
    }

    public var intentDescription: String {
        switch self {
        case .nat:
            return "Internet via the host. A VM with no networkId uses this implicitly. "
                + "Publish a service with port forwards on the VM — that is not a separate mode."
        case .bridged:
            return "The VM gets its own address on the local network (Home Network)."
        case .isolated:
            return "Private: the VM cannot reach the host, LAN, or internet "
                + "(QEMU user net with restrict=on)."
        }
    }

    /// `hostfwd` / Published Service only works on slirp NAT.
    public var allowsPortForwards: Bool {
        self == .nat
    }
}

/// Wave 0 network modes (`nat` | `bridged` | `isolated`). Tailnet is deferred.
public enum NetworkCapability {
    public static let modes = NetworkMode.allCases.map(\.rawValue)

    public static func parse(_ raw: String) throws -> NetworkMode {
        guard let mode = NetworkMode(rawValue: raw) else {
            throw BarkVisorError.badRequest(
                "mode must be 'nat', 'bridged', or 'isolated'",
            )
        }
        return mode
    }

    public static func requireMode(_ mode: String) throws {
        switch try parse(mode) {
        case .nat, .isolated:
            break
        case .bridged:
            try PlatformCapabilities.requireBridgedNetworking()
        }
    }

    /// Missing network row ⇒ implicit NAT (user slirp). Unknown persisted
    /// values fail closed.
    public static func effectiveMode(of network: Network?) throws -> NetworkMode {
        guard let network else { return .nat }
        return try parse(network.mode)
    }

    public static func requirePortForwardsAllowed(
        count: Int,
        mode: NetworkMode,
    ) throws {
        guard count > 0 else { return }
        guard mode.allowsPortForwards else {
            throw BarkVisorError.invalidPortForward(
                "Port forwards require NAT. Mode '\(mode.rawValue)' does not support hostfwd. "
                    + "Published services are NAT plus VM port forwards, not a separate mode.",
            )
        }
    }

    public static func requirePortForwardsAllowed(
        count: Int,
        network: Network?,
    ) throws {
        try requirePortForwardsAllowed(count: count, mode: effectiveMode(of: network))
    }

    /// Spec `networks[].mode` must match the attached record (or implicit NAT).
    public static func requireSpecNetwork(_ net: WorkloadNetwork, record: Network?) throws {
        let recordMode = try effectiveMode(of: record)
        if let raw = net.mode, !raw.isEmpty {
            let specMode = try parse(raw)
            if specMode != recordMode {
                let attached = record?.id ?? "implicit-nat"
                throw BarkVisorError.badRequest(
                    "spec.networks[].mode '\(specMode.rawValue)' does not match network "
                        + "\(attached) mode '\(recordMode.rawValue)'",
                )
            }
        }
        try requirePortForwardsAllowed(count: net.portForwards.count, mode: recordMode)
    }

    /// Fail closed before persist or QEMU (PAS-57).
    ///
    /// Checks product bridged capability, IFNAMSIZ-safe name, that the host
    /// interface exists (`HostInfoService.interfaceExists`), and (Linux) that
    /// a readable qemu-bridge-helper ACL allows the name.
    public static func requireBridgedInterface(_ name: String) throws {
        try PlatformCapabilities.requireBridgedNetworking()
        try validateBridgeName(name)
        guard HostInfoService.interfaceExists(name) else {
            throw BarkVisorError.interfaceMissing(name)
        }
        #if os(Linux)
            if let allowed = LinuxHostNetwork.bridgeACLDecision(name), !allowed {
                throw BarkVisorError.bridgeHelperDenied(name)
            }
        #endif
    }
}
