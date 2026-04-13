import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct HostInterface: Content {
    let name: String
    let displayName: String
    let ipAddress: String
    let bridgeStatus: String? // "active", "installed", or "not_configured"
}

struct BridgeInfo: Content {
    let interface: String
    let socketPath: String?
    let plistExists: Bool
    let daemonRunning: Bool
    let status: String // "active", "installed", "not_configured"
}

struct BridgeRequest: Content {
    let interface: String
}

struct BridgeActionResponse: Content {
    let success: Bool
    let message: String?
}

struct OnboardingStatus: Content {
    let complete: Bool
}

struct AppInfoResponse: Content {
    let version: String
    let licenses: [LicenseEntry]
}

struct LicenseEntry: Content {
    let name: String
    let license: String
    let url: String
    let description: String
}

struct BrowseEntry: Content {
    let name: String
    let path: String
    let isDirectory: Bool
}

struct VirtioWinStatusResponse: Content {
    let available: Bool
    let imageId: String?
}

struct VirtioWinDownloadResponse: Content {
    let imageId: String
}

// swiftlint:disable file_length
struct SystemController: RouteCollection {
    let imageDownloader: ImageDownloader

    func boot(routes: any RoutesBuilder) throws {
        let system = routes.grouped("api", "system")
        system.get("interfaces", use: listInterfaces)
        system.get("onboarding", use: getOnboarding)
        system.post("onboarding", "complete", use: completeOnboarding)
        system.get("about", use: getAbout)
        system.get("browse", use: browseDirectory)

        // Bridge management
        system.get("bridges", use: listBridges)
        system.post("bridges", use: installBridge)
        system.post("bridges", ":interface", "start", use: startBridge)
        system.post("bridges", ":interface", "stop", use: stopBridge)
        system.delete("bridges", ":interface", use: removeBridge)

        // USB devices
        system.get("usb-devices", use: listUSBDevices)

        // Firmware
        system.get("virtio-win", "status", use: virtioWinStatus)
        system.post("virtio-win", "download", use: virtioWinDownload)
    }

    // MARK: - Onboarding

    @Sendable
    func getOnboarding(req: Vapor.Request) async throws -> OnboardingStatus {
        let setting = try await req.db.read { db in
            try AppSetting.fetchOne(db, key: "onboarding_complete")
        }
        return OnboardingStatus(complete: setting?.value == "true")
    }

    @Sendable
    func completeOnboarding(req: Vapor.Request) async throws -> OnboardingStatus {
        try await req.db.write { db in
            let setting = AppSetting(key: "onboarding_complete", value: "true")
            try setting.save(db, onConflict: .replace)
        }
        return OnboardingStatus(complete: true)
    }

    // MARK: - About / Licenses

    @Sendable
    func getAbout(req: Vapor.Request) async throws -> AppInfoResponse {
        AppInfoResponse(
            version: Config.version,
            licenses: [
                LicenseEntry(
                    name: "QEMU",
                    license: "GPL-2.0",
                    url: "https://www.qemu.org/",
                    description: "Machine emulator and virtualizer. Source code available at qemu.org.",
                ),
                LicenseEntry(
                    name: "edk2 / OVMF / AAVMF",
                    license: "BSD-2-Clause",
                    url: "https://github.com/tianocore/edk2",
                    description: "UEFI firmware for virtual machines.",
                ),
                LicenseEntry(
                    name: "swtpm",
                    license: "BSD-3-Clause",
                    url: "https://github.com/stefanberger/swtpm",
                    description: "Software TPM 2.0 emulator.",
                ),
                LicenseEntry(
                    name: "libtpms",
                    license: "BSD-3-Clause",
                    url: "https://github.com/stefanberger/libtpms",
                    description: "TPM emulation library.",
                ),
                LicenseEntry(
                    name: "socket_vmnet",
                    license: "Apache-2.0",
                    url: "https://github.com/lima-vm/socket_vmnet",
                    description: "Bridged networking for QEMU on macOS.",
                ),
                LicenseEntry(
                    name: "virtio-win",
                    license: "Red Hat (various)",
                    url: "https://github.com/virtio-win/virtio-win-pkg-scripts",
                    description: "VirtIO drivers for Windows guests.",
                ),
                LicenseEntry(
                    name: "noVNC",
                    license: "MPL-2.0",
                    url: "https://novnc.com/",
                    description: "HTML5 VNC client for browser-based display.",
                ),
                LicenseEntry(
                    name: "xterm.js",
                    license: "MIT",
                    url: "https://xtermjs.org/",
                    description: "Terminal emulator for the serial console.",
                ),
                LicenseEntry(
                    name: "Vue.js",
                    license: "MIT",
                    url: "https://vuejs.org/",
                    description: "Frontend framework.",
                ),
                LicenseEntry(
                    name: "Vapor",
                    license: "MIT",
                    url: "https://vapor.codes/",
                    description: "Swift HTTP server framework.",
                ),
                LicenseEntry(
                    name: "GRDB.swift",
                    license: "MIT",
                    url: "https://github.com/groue/GRDB.swift",
                    description: "SQLite toolkit for Swift.",
                ),
                LicenseEntry(
                    name: "XZ Utils",
                    license: "Public domain / LGPL-2.1",
                    url: "https://tukaani.org/xz/",
                    description: "XZ/LZMA decompression tool (bundled).",
                ),
            ],
        )
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

    @Sendable
    func listInterfaces(req: Vapor.Request) async throws -> [HostInterface] {
        let bridgeRecords = try await req.db.read { db in
            try BridgeRecord.fetchAll(db)
        }
        let bridgeByInterface = Dictionary(
            uniqueKeysWithValues: bridgeRecords.map { ($0.interface, $0) },
        )

        let rawInterfaces = HostInfoService.listInterfaces()
        return rawInterfaces.map { iface in
            let displayName: String =
                if iface.name.hasPrefix("en") {
                    "\(iface.name) (Ethernet/Wi-Fi)"
                } else if iface.name.hasPrefix("bridge") {
                    "\(iface.name) (Bridge)"
                } else if iface.name == "lo0" {
                    "lo0 (Loopback)"
                } else {
                    iface.name
                }

            let bridge = bridgeByInterface[iface.name]
            return HostInterface(
                name: iface.name,
                displayName: displayName,
                ipAddress: iface.ipAddress,
                bridgeStatus: bridge?.status == "not_configured" ? nil : bridge?.status,
            )
        }
    }

    // MARK: - USB Devices

    struct HostUSBDeviceResponse: Content {
        let vendorId: String
        let productId: String
        let name: String
        let manufacturer: String?
        let serialNumber: String?
        let claimedByVMId: String?
        let claimedByVMName: String?
    }

    @Sendable
    func listUSBDevices(req: Vapor.Request) async throws -> [HostUSBDeviceResponse] {
        let hostDevices = try USBDeviceService.listDevices()

        // Build a map of claimed USB devices (vendorId:productId → VM)
        let allVMs = try await req.db.read { db in try VM.fetchAll(db) }
        var claimed: [String: (id: String, name: String)] = [:]
        for vm in allVMs {
            let devs = JSONColumnCoding.decodeArray(USBPassthroughDevice.self, from: vm.usbDevices) ?? []
            for dev in devs {
                claimed["\(dev.vendorId):\(dev.productId)"] = (id: vm.id, name: vm.name)
            }
        }

        return hostDevices.map { dev in
            let key = "\(dev.vendorId):\(dev.productId)"
            let claim = claimed[key]
            return HostUSBDeviceResponse(
                vendorId: dev.vendorId,
                productId: dev.productId,
                name: dev.name,
                manufacturer: dev.manufacturer,
                serialNumber: dev.serialNumber,
                claimedByVMId: claim?.id,
                claimedByVMName: claim?.name,
            )
        }
    }

    // MARK: - Bridge Management

    @Sendable
    func listBridges(req: Vapor.Request) async throws -> [BridgeInfo] {
        let records = try await req.db.read { db in
            try BridgeRecord.fetchAll(db)
        }
        return records.map { r in
            BridgeInfo(
                interface: r.interface,
                socketPath: r.socketPath,
                plistExists: r.plistExists,
                daemonRunning: r.daemonRunning,
                status: r.status,
            )
        }
    }

    @Sendable
    func installBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        let body = try req.content.decode(BridgeRequest.self)
        let iface = body.interface

        // Validate interface exists on the host
        guard HostInfoService.interfaceExists(iface) else {
            throw Abort(.badRequest, reason: "Interface '\(iface)' not found on this host")
        }

        // Check if a bridge already exists for this interface
        let existingBridge = try await req.db.read { db in
            try BridgeRecord.filter(Column("interface") == iface).fetchOne(db)
        }
        if let existingBridge, existingBridge.status != "not_configured" {
            throw Abort(
                .conflict,
                reason: "Bridge already exists for interface '\(iface)' (status: \(existingBridge.status))",
            )
        }

        // Delegate to privileged helper via XPC
        do {
            try await HelperXPCClient.shared.installBridge(interface: iface)
            // Immediate sync so DB reflects the change
            let db = req.db
            Task { await BridgeSyncService.syncOnce(db: db) }

            // Auto-create a bridged network if none exists for this interface
            let existingNetwork = try await req.db.read { db in
                try Network.filter(Column("bridge") == iface).fetchOne(db)
            }
            if existingNetwork == nil {
                let network = Network(
                    id: UUID().uuidString,
                    name: "Bridged (\(iface))",
                    mode: "bridged",
                    bridge: iface,
                    macAddress: nil,
                    dnsServer: nil,
                    autoCreated: true,
                    isDefault: false,
                )
                try await req.db.write { db in
                    try network.insert(db)
                }
                AuditService.log(
                    action: "network.create", resourceType: "network", resourceId: network.id,
                    resourceName: network.name, req: req,
                )
            }

            return BridgeActionResponse(success: true, message: "Bridge installed for \(iface)")
        } catch {
            Log.server.error("Failed to install bridge for \(iface): \(error)")
            throw Abort(
                .internalServerError, reason: "Failed to install bridge: \(error.localizedDescription)",
            )
        }
    }

    @Sendable
    func startBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        guard let iface = req.parameters.get("interface") else {
            throw Abort(.badRequest, reason: "Missing interface parameter")
        }
        guard HostInfoService.interfaceExists(iface) else {
            throw Abort(.badRequest, reason: "Interface '\(iface)' not found on this host")
        }

        do {
            try await HelperXPCClient.shared.startBridge(interface: iface)
            await BridgeSyncService.syncOnce(db: req.db)
            return BridgeActionResponse(success: true, message: "Bridge started for \(iface)")
        } catch {
            Log.server.error("Failed to start bridge for \(iface): \(error)")
            throw Abort(
                .internalServerError, reason: "Failed to start bridge: \(error.localizedDescription)",
            )
        }
    }

    @Sendable
    func stopBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        guard let iface = req.parameters.get("interface") else {
            throw Abort(.badRequest, reason: "Missing interface parameter")
        }
        guard HostInfoService.interfaceExists(iface) else {
            throw Abort(.badRequest, reason: "Interface '\(iface)' not found on this host")
        }

        do {
            try await HelperXPCClient.shared.stopBridge(interface: iface)
            await BridgeSyncService.syncOnce(db: req.db)
            return BridgeActionResponse(success: true, message: "Bridge stopped for \(iface)")
        } catch {
            Log.server.error("Failed to stop bridge for \(iface): \(error)")
            throw Abort(
                .internalServerError, reason: "Failed to stop bridge: \(error.localizedDescription)",
            )
        }
    }

    @Sendable
    func removeBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        guard let iface = req.parameters.get("interface") else {
            throw Abort(.badRequest, reason: "Missing interface parameter")
        }
        guard HostInfoService.interfaceExists(iface) else {
            throw Abort(.badRequest, reason: "Interface '\(iface)' not found on this host")
        }

        do {
            try await HelperXPCClient.shared.removeBridge(interface: iface)
            await BridgeSyncService.syncOnce(db: req.db)
            return BridgeActionResponse(success: true, message: "Bridge removed for \(iface)")
        } catch {
            Log.server.error("Failed to remove bridge for \(iface): \(error)")
            throw Abort(
                .internalServerError, reason: "Failed to remove bridge: \(error.localizedDescription)",
            )
        }
    }

    // MARK: - VirtIO Windows Drivers

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
// swiftlint:enable file_length
