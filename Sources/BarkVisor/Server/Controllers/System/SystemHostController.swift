import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct SystemHostController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let system = routes.grouped("api", "system")
        system.get("interfaces", use: listInterfaces)
        system.get("browse", use: browseDirectory)
        system.get("usb-devices", use: listUSBDevices)
        system.get("usb", use: listUSBDevices)
    }

    // MARK: - Directory Browser

    /// Allowed root directories for the directory browser.
    /// Only paths under the user's home directory or /Volumes are browsable.
    private static let allowedRoots: [String] = [
        NSHomeDirectory(),
        "/Volumes",
    ]

    @Sendable
    func browseDirectory(req: Vapor.Request) async throws -> [BrowseEntry] {
        let rawPath = (try? req.query.get(String.self, at: "path")) ?? NSHomeDirectory()

        // Resolve symlinks and canonicalize to prevent traversal via symlinks or ../
        let resolvedPath = (rawPath as NSString).resolvingSymlinksInPath

        // Validate the resolved path is within an allowed root directory (use trailing slash to prevent prefix bypass)
        let isAllowed = Self.allowedRoots.contains(where: { root in
            let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
            return resolvedPath == root || resolvedPath.hasPrefix(rootWithSlash)
        })
        guard isAllowed || resolvedPath == "/" else {
            throw Abort(.forbidden, reason: "Access denied: path is outside allowed directories")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue
        else {
            throw Abort(.badRequest, reason: "Path is not a directory")
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: resolvedPath)
        var entries: [BrowseEntry] = []

        // Parent directory (only if still within allowed roots)
        if resolvedPath != "/" {
            let parent = (resolvedPath as NSString).deletingLastPathComponent
            let parentResolved = (parent as NSString).resolvingSymlinksInPath
            let parentAllowed = Self.allowedRoots.contains(where: { root in
                let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
                return parentResolved == root || parentResolved.hasPrefix(rootWithSlash)
            })
            if parentAllowed || parentResolved == "/" {
                entries.append(BrowseEntry(name: "..", path: parent, isDirectory: true))
            }
        }

        for name in contents.sorted() {
            // Skip hidden files
            if name.hasPrefix(".") { continue }
            let fullPath = (resolvedPath as NSString).appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &childIsDir)
            if childIsDir.boolValue {
                entries.append(BrowseEntry(name: name, path: fullPath, isDirectory: true))
            }
        }

        return entries
    }

    // MARK: - Host Interfaces

    @Sendable
    func listInterfaces(req: Vapor.Request) async throws -> [HostInterface] {
        let bridgeStatusByInterface = try await req.db.read { db in
            try Dictionary(
                uniqueKeysWithValues: BridgeRecord.fetchAll(db).map { ($0.interface, $0.status) },
            )
        }
        return HostInfoService.listInterfaceSnapshots(
            bridgeStatusByInterface: bridgeStatusByInterface,
        ).map {
            HostInterface(
                name: $0.name,
                displayName: $0.displayName,
                ipAddress: $0.ipAddress,
                bridgeStatus: $0.bridgeStatus,
            )
        }
    }

    // MARK: - USB Devices

    @Sendable
    func listUSBDevices(req: Vapor.Request) async throws -> [HostUSBDeviceResponse] {
        guard PlatformCapabilities.supportsUSBPassthrough else {
            return []
        }
        let hostDevices = try USBDeviceService.listDevices()
        let allVMs = try await req.db.read { db in try VM.fetchAll(db) }

        return hostDevices.map { dev in
            let claim = USBPassthroughService.claimedBy(host: dev, vms: allVMs)
            return HostUSBDeviceResponse(
                id: dev.id,
                vendorId: dev.vendorId,
                productId: dev.productId,
                name: dev.name,
                productName: dev.productName,
                manufacturer: dev.manufacturer,
                serial: dev.serialNumber,
                serialNumber: dev.serialNumber,
                bus: dev.bus,
                address: dev.address,
                idUnstable: dev.idUnstable,
                attachable: dev.attachable,
                excludedReason: dev.excludedReason,
                busy: claim != nil,
                attachedToVmId: claim?.id,
                claimedByVMId: claim?.id,
                claimedByVMName: claim?.name,
            )
        }
    }
}
