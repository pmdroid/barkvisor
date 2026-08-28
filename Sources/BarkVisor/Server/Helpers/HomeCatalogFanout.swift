import BarkVisorCore
import Foundation

enum HomeCatalogFanout {
    static func publish(repoType: String, data: Data) async {
        let listed = HomeDeviceDirectory.list(dataDir: Config.dataDir, hostId: Config.hostId)
        guard let client = try? HomeDevicesMTLS.client(dataDir: Config.dataDir, hostId: Config.hostId)
        else { return }
        await HomeCatalogPlane.publish(
            repoType: repoType,
            data: data,
            members: listed.devices,
            send: { url, body in
                _ = try await send(client: client, method: "PUT", url: url, body: body)
            },
        )
    }

    static func pullMissing() async {
        let listed = HomeDeviceDirectory.list(dataDir: Config.dataDir, hostId: Config.hostId)
        guard let client = try? HomeDevicesMTLS.client(dataDir: Config.dataDir, hostId: Config.hostId)
        else { return }
        await HomeCatalogPlane.pull(
            peers: listed.devices,
            lastGood: LastGoodCatalogStore(directory: Config.dataDir),
            get: { url in
                try await send(client: client, method: "GET", url: url, body: nil)
            },
        )
    }

    private static func send(
        client: AgentMTLSClient,
        method: String,
        url: URL,
        body: Data?,
    ) async throws -> Data {
        let result = try await client.send(
            HomeDeviceProxyRequest(
                method: method,
                url: url,
                headers: [
                    ("Content-Type", "application/json"),
                    (APIContract.versionHeaderName, String(APIContract.version)),
                ],
                body: body,
            ),
        )
        guard (200 ..< 300).contains(result.status) else {
            throw BarkVisorError.badGateway("HTTP \(result.status)")
        }
        return result.body
    }
}
