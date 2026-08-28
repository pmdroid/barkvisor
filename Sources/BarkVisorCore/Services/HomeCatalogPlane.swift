import Foundation

public enum HomeCatalogPlane {
    public static let appliedPrefix = "/api/catalogs/applied/"

    public static func appliedPath(repoType: String) -> String {
        appliedPrefix + repoType
    }

    public static func repoType(path: String) -> String? {
        var normalized = path
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }
        guard normalized.hasPrefix(appliedPrefix) else { return nil }
        let rest = String(normalized.dropFirst(appliedPrefix.count))
        if rest == "images" || rest == "templates" {
            return rest
        }
        return nil
    }

    public static func publish(
        repoType: String,
        data: Data,
        members: [HomeDevice],
        send: @Sendable (URL, Data) async throws -> Void,
    ) async {
        let path = appliedPath(repoType: repoType)
        for device in members where device.role != "self" {
            guard let host = device.agentHost, !host.isEmpty else { continue }
            guard let url = try? HomeDeviceProxy.memberURL(
                host: host, port: device.agentPort, path: path,
            ) else { continue }
            try? await send(url, data)
        }
    }

    public static func pull(
        repoTypes: [String] = HomeCatalogOrigin.repoTypes,
        peers: [HomeDevice],
        lastGood: LastGoodCatalogStore,
        get: @Sendable (URL) async throws -> Data,
    ) async {
        let targets = peers.filter { $0.role != "self" }
        for repoType in repoTypes {
            if let existing = lastGood.load(repoType: repoType), !existing.isEmpty {
                continue
            }
            for device in targets {
                guard let host = device.agentHost, !host.isEmpty else { continue }
                guard let url = try? HomeDeviceProxy.memberURL(
                    host: host, port: device.agentPort, path: appliedPath(repoType: repoType),
                ) else { continue }
                guard let data = try? await get(url), !data.isEmpty else { continue }
                try? lastGood.save(repoType: repoType, data: data)
                break
            }
        }
    }
}
