import Foundation

/// Detected Tailscale tailnet (PAS-89). BarkVisor does not bundle Tailscale;
/// this is a read of `tailscale` if the operator installed it.
public struct TailnetInfo: Codable, Sendable, Equatable {
    public var available: Bool
    public var ip: String?
    public var dnsName: String?

    public init(available: Bool, ip: String? = nil, dnsName: String? = nil) {
        self.available = available
        self.ip = ip
        self.dnsName = dnsName
    }

    public static let unavailable = TailnetInfo(available: false)
}

public struct WireGuardInfo: Codable, Sendable, Equatable {
    public var configured: Bool

    public init(configured: Bool) {
        self.configured = configured
    }
}

/// GET `/api/system/remote-access` and PUT `/api/home/settings/remote-access`.
public struct RemoteAccessStatus: Codable, Sendable, Equatable {
    public var tailscale: TailnetInfo
    public var wireguard: WireGuardInfo
    public var advertiseUrl: String?
    public var requireTailnetForRemote: Bool

    public init(
        tailscale: TailnetInfo,
        wireguard: WireGuardInfo,
        advertiseUrl: String?,
        requireTailnetForRemote: Bool,
    ) {
        self.tailscale = tailscale
        self.wireguard = wireguard
        self.advertiseUrl = advertiseUrl
        self.requireTailnetForRemote = requireTailnetForRemote
    }
}
