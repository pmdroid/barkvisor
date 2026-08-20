import Foundation
import GRDB

/// Persisted remote-access policy (PAS-89). LAN stays usable without a VPN.
public enum RemoteAccessSettings {
    public static let requireKey = "remote_access.require_tailnet"
    public static let advertiseUrlKey = "remote_access.advertise_url"

    public struct Snapshot: Sendable, Equatable {
        public var requireTailnetForRemote: Bool
        public var advertiseUrl: String?

        public init(requireTailnetForRemote: Bool = false, advertiseUrl: String? = nil) {
            self.requireTailnetForRemote = requireTailnetForRemote
            self.advertiseUrl = advertiseUrl
        }
    }

    public static func load(from db: Database) throws -> Snapshot {
        let requireRaw = try AppSetting.fetchOne(db, key: requireKey)?.value ?? ""
        let urlRaw = try AppSetting.fetchOne(db, key: advertiseUrlKey)?.value ?? ""
        let require = ["1", "true", "yes"].contains(
            requireRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        )
        let url = urlRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Snapshot(
            requireTailnetForRemote: require,
            advertiseUrl: url.isEmpty ? nil : url,
        )
    }

    /// Empty/whitespace ⇒ clear. Otherwise a pairing-safe host (scheme/port stripped).
    public static func parseAdvertiseHost(_ raw: String?) throws -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let host = try extractHost(trimmed)
        guard let clean = PairingPayload.sanitizeHost(host) else {
            throw BarkVisorError.badRequest(
                "Invalid advertise URL. Use a LAN IP, Tailscale address, or DNS name "
                    + "— not localhost, .internal, or a public/metadata address.",
            )
        }
        return clean
    }

    public static func save(
        requireTailnetForRemote: Bool? = nil,
        advertiseUrl: String? = nil,
        updateAdvertiseUrl: Bool = false,
        db: Database,
    ) throws -> Snapshot {
        if let requireTailnetForRemote {
            try AppSetting(
                key: requireKey,
                value: requireTailnetForRemote ? "true" : "false",
            ).save(db, onConflict: .replace)
        }
        if updateAdvertiseUrl {
            if let host = try parseAdvertiseHost(advertiseUrl) {
                try AppSetting(key: advertiseUrlKey, value: host).save(db, onConflict: .replace)
            } else {
                _ = try AppSetting.deleteOne(db, key: advertiseUrlKey)
            }
        }
        requireCache.reset()
        return try load(from: db)
    }

    public static func advertisedHosts(advertiseUrl: String?) -> [String] {
        PairingAddresses.advertisedHosts(
            tailnet: TailscaleProbe.detect(),
            advertiseUrl: advertiseUrl,
        )
    }

    public static func status(settings: Snapshot) -> RemoteAccessStatus {
        RemoteAccessStatus(
            tailscale: TailscaleProbe.detect(),
            wireguard: WireGuardProbe.detect(),
            advertiseUrl: settings.advertiseUrl,
            requireTailnetForRemote: settings.requireTailnetForRemote,
        )
    }

    public static let requireCacheTTL: TimeInterval = 5

    public static func cachedRequireTailnet(from db: Database, now: Date = Date()) throws -> Bool {
        if let cached = requireCache.load(now: now) {
            return cached
        }
        let value = try load(from: db).requireTailnetForRemote
        requireCache.store(value, now: now)
        return value
    }

    /// Loopback, RFC1918, ULA, and CGNAT `100.64.0.0/10` (minus metadata).
    /// Fail closed on empty, hostname-shaped, or unclassified peer strings.
    public static func allowsPeer(_ ip: String?) -> Bool {
        guard let ip, !ip.isEmpty else { return false }
        if PairingPayload.isConsoleLocalClient(ip) { return true }
        let trimmed = ip.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let looksIP = trimmed.contains(":") || trimmed.split(separator: ".").count == 4
        guard looksIP else { return false }
        return !PairingPayload.isBlockedJoinHost(ip)
    }

    private static func extractHost(_ raw: String) throws -> String {
        if raw.contains("://") {
            guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
                throw BarkVisorError.badRequest("Invalid advertise URL")
            }
            return host
        }
        if raw.contains("/") {
            throw BarkVisorError.badRequest("Invalid advertise URL")
        }
        var host = raw
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let inner = String(host[host.index(after: host.startIndex) ..< close])
            let rest = host[host.index(after: close)...]
            if rest.isEmpty || rest.hasPrefix(":") {
                return inner
            }
        }
        if let colon = host.lastIndex(of: ":"), !host.contains("]") {
            let after = host[host.index(after: colon)...]
            if !after.isEmpty, after.allSatisfy(\.isNumber) {
                host = String(host[..<colon])
            }
        }
        return host
    }

    private static let requireCache = RequireFlagCache()
}

private final class RequireFlagCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (flag: Bool, expiresAt: Date)?

    func load(now: Date) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let value, value.expiresAt > now else { return nil }
        return value.flag
    }

    func store(_ flag: Bool, now: Date) {
        lock.lock()
        value = (flag, now.addingTimeInterval(RemoteAccessSettings.requireCacheTTL))
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}
