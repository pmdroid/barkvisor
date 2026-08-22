import BarkVisorCore
import Foundation
import GRDB
import Vapor

/// Home-wide Library metadata (PAS-39). Blobs stay on each Device.
///
/// Listing fans out `GET /api/images` (JSON only). Prefetch tells the target
/// Device to copy bytes on the agent plane — never through the 10 MiB Home
/// proxy. This is not content-addressed storage.
struct HomeLibraryController: RouteCollection {
    var devices: DeviceRegistry?
    var mtlsClient: (any HomeDeviceProxyClient)?
    var dataDir: URL
    var hostId: String
    var prefetch: LibraryPrefetch?

    init(
        dataDir: URL = Config.dataDir,
        hostId: String = Config.hostId,
        devices: DeviceRegistry? = nil,
        mtlsClient: (any HomeDeviceProxyClient)? = nil,
        prefetch: LibraryPrefetch? = nil,
    ) {
        self.dataDir = dataDir
        self.hostId = hostId
        self.devices = devices
        self.mtlsClient = mtlsClient
        self.prefetch = prefetch
    }

    func boot(routes: any RoutesBuilder) throws {
        let library = routes.grouped("api", "home", "library")
        library.get("images", use: list)
        library.post("images", "prefetch", use: prefetchImage)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> HomeLibraryList {
        _ = try req.requireUser
        return await catalog(db: req.db, bearer: req.headers.bearerAuthorization?.token)
    }

    @Sendable
    func prefetchImage(req: Vapor.Request) async throws -> HomeLibraryPrefetchResponse {
        _ = try req.requireUser
        let body = try req.content.decode(HomeLibraryPrefetchRequest.self)
        guard !body.libraryKey.isEmpty, !body.hostId.isEmpty else {
            throw Abort(.badRequest, reason: "libraryKey and hostId are required")
        }
        return try await prefetch(
            body,
            db: req.db,
            bearer: req.headers.bearerAuthorization?.token,
        )
    }

    func catalog(db: DatabasePool, bearer: String?) async -> HomeLibraryList {
        let listed = listedDevices()
        let local: [HomeLibraryDeviceImage]
        do {
            local = try await db.read { db in
                try VMImage.fetchAll(db).map(HomeLibraryDeviceImage.init(from:))
            }
        } catch {
            local = []
        }
        var batches: [(hostId: String, images: [HomeLibraryDeviceImage])] = [
            (hostId, local),
        ]
        let members = listed.devices.filter { $0.role != "self" }
        await withTaskGroup(of: (String, [HomeLibraryDeviceImage]).self) { group in
            for device in members {
                group.addTask {
                    await (device.hostId, self.memberImages(device, bearer: bearer))
                }
            }
            for await (id, images) in group where !images.isEmpty {
                batches.append((id, images))
            }
        }
        return HomeLibraryList(images: HomeLibraryCatalog.merge(batches))
    }

    func prefetch(
        _ request: HomeLibraryPrefetchRequest,
        db: DatabasePool,
        bearer: String?,
    ) async throws -> HomeLibraryPrefetchResponse {
        let listed = listedDevices()
        guard listed.devices.contains(where: { $0.hostId == request.hostId }) else {
            throw BarkVisorError.notFound("Device not found")
        }
        let images = await catalog(db: db, bearer: bearer).images
        guard let row = images.first(where: { $0.libraryKey == request.libraryKey }) else {
            throw BarkVisorError.notFound("Library image not found")
        }
        if let existing = HomeLibraryCatalog.copy(of: row, hostId: request.hostId),
           existing.status == "ready" || existing.status == "downloading" {
            let image = representative(row, imageId: existing.imageId, status: existing.status)
            return HomeLibraryPrefetchResponse(
                libraryKey: row.libraryKey, hostId: request.hostId, image: image,
            )
        }
        guard let source = HomeLibraryCatalog.sourceCopy(of: row, excluding: request.hostId) else {
            throw BarkVisorError.conflict("No Device has a local copy to prefetch from")
        }
        let body = ImagePrefetchRequest(
            sourceHostId: source.hostId,
            sourceImageId: source.imageId,
            name: row.name,
            imageType: row.imageType,
            arch: row.arch,
            sourceUrl: row.sourceUrl,
            sha256: row.sha256,
        )
        if request.hostId == hostId {
            let started = try await localPrefetch().start(body, db: db)
            return HomeLibraryPrefetchResponse(
                libraryKey: row.libraryKey,
                hostId: request.hostId,
                image: HomeLibraryDeviceImage(from: started),
            )
        }
        let member = try memberDevice(request.hostId, listed: listed)
        let fetched = try await postPrefetch(member, body: body, bearer: bearer)
        return HomeLibraryPrefetchResponse(
            libraryKey: row.libraryKey, hostId: request.hostId, image: fetched,
        )
    }

    private func representative(
        _ row: HomeLibraryImage,
        imageId: String,
        status: String,
    ) -> HomeLibraryDeviceImage {
        HomeLibraryDeviceImage(
            id: imageId,
            name: row.name,
            imageType: row.imageType,
            arch: row.arch,
            status: status,
            sizeBytes: row.sizeBytes,
            sourceUrl: row.sourceUrl,
            error: row.error,
            sha256: row.sha256,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
        )
    }

    private func listedDevices() -> HomeDeviceList {
        HomeDeviceDirectory.list(
            dataDir: dataDir,
            hostId: hostId,
            displayName: ProcessInfo.processInfo.hostName,
            devices: devices,
        )
    }

    private func localPrefetch() throws -> LibraryPrefetch {
        if let prefetch {
            return prefetch
        }
        return LibraryPrefetch(
            localHostId: hostId,
            dataDir: dataDir,
            devices: devices ?? DeviceRegistry(dataDir: dataDir),
            openClient: { record in
                try LibraryDepotClients.make(record: record, dataDir: self.dataDir, hostId: self.hostId)
            },
        )
    }

    private func memberDevice(_ hostId: String, listed: HomeDeviceList) throws -> HomeDevice {
        guard let device = listed.devices.first(where: { $0.hostId == hostId }) else {
            throw BarkVisorError.notFound("Device not found")
        }
        return device
    }

    private func memberImages(_ device: HomeDevice, bearer: String?) async -> [HomeLibraryDeviceImage] {
        guard let agentHost = device.agentHost, !agentHost.isEmpty else {
            return []
        }
        guard let client = try? proxyClient() else {
            return []
        }
        let url: URL
        do {
            url = try HomeDeviceProxy.memberURL(
                host: agentHost, port: device.agentPort, path: "/api/images",
            )
        } catch {
            return []
        }
        do {
            let data = try await getJSON(url: url, client: client, bearer: bearer)
            return try JSONDecoder().decode([HomeLibraryDeviceImage].self, from: data)
        } catch {
            return []
        }
    }

    private func postPrefetch(
        _ device: HomeDevice,
        body: ImagePrefetchRequest,
        bearer: String?,
    ) async throws -> HomeLibraryDeviceImage {
        guard let agentHost = device.agentHost, !agentHost.isEmpty else {
            throw BarkVisorError.notFound("Device has no reachable address")
        }
        let client = try proxyClient()
        let url = try HomeDeviceProxy.memberURL(
            host: agentHost, port: device.agentPort, path: "/api/images/prefetch",
        )
        var headers: [(String, String)] = [
            ("Accept", "application/json"),
            ("Content-Type", "application/json"),
            (APIContract.versionHeaderName, String(APIContract.version)),
        ]
        if let bearer {
            headers.append(("Authorization", "Bearer \(bearer)"))
        }
        let payload = try JSONEncoder().encode(body)
        let result: HomeDeviceProxyResponse
        do {
            result = try await client.send(
                HomeDeviceProxyRequest(method: "POST", url: url, headers: headers, body: payload),
            )
        } catch let error as HomeDeviceProxyError {
            throw BarkVisorError.downloadFailed(error.localizedDescription)
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw BarkVisorError.downloadFailed(
                "Device is unreachable: \(error.localizedDescription)",
            )
        }
        guard (200 ..< 300).contains(result.status) else {
            throw BarkVisorError.downloadFailed("member prefetch returned HTTP \(result.status)")
        }
        if let decoded = try? JSONDecoder().decode(HomeLibraryDeviceImage.self, from: result.body) {
            return decoded
        }
        // ImageResponse and HomeLibraryDeviceImage share keys; ImageResponse is the member body.
        throw BarkVisorError.downloadFailed("member prefetch returned an unexpected body")
    }

    private func proxyClient() throws -> any HomeDeviceProxyClient {
        if let mtlsClient {
            return mtlsClient
        }
        do {
            return try HomeDevicesMTLS.client(dataDir: dataDir, hostId: hostId)
        } catch {
            throw BarkVisorError.internalError(
                "This Device cannot reach members yet; local runtime continues",
            )
        }
    }

    private func getJSON(
        url: URL,
        client: any HomeDeviceProxyClient,
        bearer: String?,
    ) async throws -> Data {
        var headers: [(String, String)] = [
            ("Accept", "application/json"),
            (APIContract.versionHeaderName, String(APIContract.version)),
        ]
        if let bearer {
            headers.append(("Authorization", "Bearer \(bearer)"))
        }
        let result = try await client.send(
            HomeDeviceProxyRequest(method: "GET", url: url, headers: headers, body: nil),
        )
        guard (200 ..< 300).contains(result.status) else {
            throw HomeDeviceProxyError.unreachable("member returned HTTP \(result.status)")
        }
        return result.body
    }
}
