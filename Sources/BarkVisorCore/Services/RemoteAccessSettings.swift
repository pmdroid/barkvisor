import Foundation
import GRDB

public enum RemoteAccessSettings {
    public static let advertiseUrlKey = "remote_access.advertise_url"

    public struct Snapshot: Sendable, Equatable {
        public var deviceUrl: String?

        public init(deviceUrl: String? = nil) {
            self.deviceUrl = deviceUrl
        }
    }

    public static func load(from db: Database) throws -> Snapshot {
        let urlRaw = try AppSetting.fetchOne(db, key: advertiseUrlKey)?.value ?? ""
        let url = urlRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Snapshot(deviceUrl: url.isEmpty ? nil : url)
    }

    public static func parseAdvertiseHost(_ raw: String?) throws -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let host = try extractHost(trimmed)
        guard let clean = PairingPayload.sanitizeHost(host) else {
            throw BarkVisorError.badRequest(
                "Invalid Device URL. Use a LAN IP, Tailscale address, or DNS name "
                    + "— not localhost, .internal, or a public/metadata address.",
            )
        }
        return clean
    }

    public static func save(
        deviceUrl: String? = nil,
        updateDeviceUrl: Bool = false,
        db: Database,
    ) throws -> Snapshot {
        if updateDeviceUrl {
            if let host = try parseAdvertiseHost(deviceUrl) {
                try AppSetting(key: advertiseUrlKey, value: host).save(db, onConflict: .replace)
            } else {
                _ = try AppSetting.deleteOne(db, key: advertiseUrlKey)
            }
        }
        return try load(from: db)
    }

    public static func advertisedHosts(deviceUrl: String?) -> [String] {
        PairingAddresses.advertisedHosts(
            tailnet: TailscaleProbe.detect(),
            advertiseUrl: deviceUrl,
            hostname: ProcessInfo.processInfo.hostName,
        )
    }

    public static func status(settings: Snapshot) -> RemoteAccessStatus {
        let tailscale = TailscaleProbe.detect()
        let hosts = PairingAddresses.advertisedHosts(
            tailnet: tailscale,
            advertiseUrl: settings.deviceUrl,
            hostname: ProcessInfo.processInfo.hostName,
        )
        return RemoteAccessStatus(
            tailscale: tailscale,
            wireguard: WireGuardProbe.detect(),
            deviceUrl: settings.deviceUrl,
            advertisedHosts: hosts,
        )
    }

    private static func extractHost(_ raw: String) throws -> String {
        if raw.contains("://") {
            guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
                throw BarkVisorError.badRequest("Invalid Device URL")
            }
            return host
        }
        if raw.contains("/") {
            throw BarkVisorError.badRequest("Invalid Device URL")
        }
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            let inner = String(raw[raw.index(after: raw.startIndex) ..< close])
            let rest = raw[raw.index(after: close)...]
            if rest.isEmpty || rest.hasPrefix(":") {
                return inner
            }
        }
        if let colon = raw.lastIndex(of: ":"), raw.firstIndex(of: ":") == colon {
            let after = raw[raw.index(after: colon)...]
            if !after.isEmpty, after.allSatisfy(\.isNumber) {
                return String(raw[..<colon])
            }
        }
        return raw
    }
}
