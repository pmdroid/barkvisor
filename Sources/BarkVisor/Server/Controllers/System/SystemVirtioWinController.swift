import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct SystemVirtioWinController: RouteCollection {
    let imageDownloader: ImageDownloader

    func boot(routes: any RoutesBuilder) throws {
        let system = routes.grouped("api", "system")
        system.get("virtio-win", "status", use: virtioWinStatus)
        system.post("virtio-win", "download", use: virtioWinDownload)
    }

    static let virtioWinURL =
        "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    static let virtioWinName = "VirtIO Windows Drivers"

    @Sendable
    func virtioWinStatus(req: Vapor.Request) async throws -> VirtioWinStatusResponse {
        let image = try await req.db.read { db in
            try VMImage
                .filter(Column("sourceUrl") == Self.virtioWinURL)
                .filter(Column("status") == "ready")
                .fetchOne(db)
        }
        return VirtioWinStatusResponse(available: image != nil, imageId: image?.id)
    }

    @Sendable
    func virtioWinDownload(req: Vapor.Request) async throws -> VirtioWinDownloadResponse {
        // Check if already downloading or ready
        let existing = try await req.db.read { db in
            try VMImage
                .filter(Column("sourceUrl") == Self.virtioWinURL)
                .filter(Column("status") == "downloading" || Column("status") == "ready")
                .fetchOne(db)
        }
        if let existing {
            return VirtioWinDownloadResponse(imageId: existing.id)
        }

        let image = try await ImageService.startDownload(
            ImageDownloadRequest(name: Self.virtioWinName, url: Self.virtioWinURL, imageType: "iso", arch: "arm64"),
            downloader: imageDownloader,
            db: req.db,
        )
        return VirtioWinDownloadResponse(imageId: image.id)
    }
}
