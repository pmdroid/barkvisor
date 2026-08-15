import BarkVisorCore
import Foundation

/// mTLS Library depot client. Never uses ``ImageDownloader`` / public URLs.
struct AgentLibraryDepotClient: LibraryDepotClient {
    var record: DeviceRecord
    var listClient: any HomeDeviceProxyClient
    var stream: AgentMTLSClient

    init(record: DeviceRecord, materialClient: AgentMTLSClient) {
        self.record = record
        self.listClient = materialClient
        self.stream = materialClient
    }

    func listImages(sourceUrl: String) async throws -> [LibraryDepotImageInfo] {
        guard let host = record.agentHost, !host.isEmpty else {
            throw HomeDeviceProxyError.unreachable("Device has no reachable address")
        }
        let encoded = sourceUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sourceUrl
        let url = try HomeDeviceProxy.memberURL(
            host: host,
            port: record.agentPort,
            path: LibraryDepotHTTP.listPath,
            query: "sourceUrl=\(encoded)",
        )
        let result = try await listClient.send(
            HomeDeviceProxyRequest(
                method: "GET",
                url: url,
                headers: [
                    ("Accept", "application/json"),
                    (APIContract.versionHeaderName, String(APIContract.version)),
                ],
            ),
        )
        guard (200 ..< 300).contains(result.status) else {
            throw HomeDeviceProxyError.unreachable("depot listing returned HTTP \(result.status)")
        }
        return try JSONDecoder().decode([LibraryDepotImageInfo].self, from: result.body)
    }

    func fetchBytes(imageId: String, to destination: URL) async throws -> LibraryDepotFetchBytes {
        guard let host = record.agentHost, !host.isEmpty else {
            throw HomeDeviceProxyError.unreachable("Device has no reachable address")
        }
        let url = try HomeDeviceProxy.memberURL(
            host: host,
            port: record.agentPort,
            path: LibraryDepotHTTP.contentPath(id: imageId),
        )
        let streamed = try await stream.streamGet(url: url, to: destination)
        guard streamed.status == 200 else {
            throw HomeDeviceProxyError.unreachable("depot bytes returned HTTP \(streamed.status)")
        }
        let filename = header(LibraryDepotHTTP.filenameHeader, in: streamed.headers)
        let reported = header(LibraryDepotHTTP.sha256Header, in: streamed.headers)
        return LibraryDepotFetchBytes(
            sha256: streamed.sha256,
            bytesWritten: streamed.bytesWritten,
            filename: filename,
            reportedSha256: reported,
        )
    }

    private func header(_ name: String, in headers: [(String, String)]) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

enum LibraryDepotClients {
    static func make(
        record: DeviceRecord,
        dataDir: URL = Config.dataDir,
        hostId: String = Config.hostId,
    ) throws -> AgentLibraryDepotClient {
        let client = try HomeDevicesMTLS.client(dataDir: dataDir, hostId: hostId)
        return AgentLibraryDepotClient(record: record, materialClient: client)
    }

    static func acquire(
        dataDir: URL = Config.dataDir,
        hostId: String = Config.hostId,
    ) -> LibraryDepotAcquire {
        LibraryDepotAcquire(
            localHostId: hostId,
            dataDir: dataDir,
            devices: DeviceRegistry(dataDir: dataDir),
            openClient: { record in
                try LibraryDepotClients.make(record: record, dataDir: dataDir, hostId: hostId)
            },
        )
    }
}
