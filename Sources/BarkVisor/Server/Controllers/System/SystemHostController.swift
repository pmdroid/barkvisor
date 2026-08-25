import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct SystemHostController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let system = routes.grouped("api", "system")
        system.get("interfaces", use: listInterfaces)
        system.get("host-bridge-readiness", use: getHostBridgeReadiness)
        system.get("browse", use: browseDirectory)
        system.get("usb-devices", use: listUSBDevices)
        system.get("usb", use: listUSBDevices)
        system.get("gpu-devices", use: listGPUDevices)
        system.get("gpu", use: listGPUDevices)
        system.get("pci-devices", use: listPCIDevices)
        system.get("block-devices", use: listBlockDevices)
    }

    @Sendable
    func getHostBridgeReadiness(req _: Vapor.Request) async throws -> HostBridgeReadiness {
        HostBridgeFactsService.readiness()
    }

    // MARK: - Directory Browser

    @Sendable
    func browseDirectory(req: Vapor.Request) async throws -> [BrowseEntry] {
        let rawPath = (try? req.query.get(String.self, at: "path")) ?? NSHomeDirectory()

        // Resolve symlinks and canonicalize to prevent traversal via symlinks or ../
        let resolvedPath = (rawPath as NSString).resolvingSymlinksInPath

        let extraRoots = try await req.db.read { db in
            [
                try LibrarySettings.resolvedDirectory(from: db).path,
                try DiskSettings.resolvedDirectory(from: db).path,
            ]
        }
        guard DirectoryBrowser.isAllowed(resolvedPath, extraRoots: extraRoots) else {
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
            if DirectoryBrowser.isAllowed(parent, extraRoots: extraRoots) {
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
        let records = try await req.db.read { db in
            try BridgeRecord.fetchAll(db)
        }
        return HostInfoService.listInterfaceSnapshots(
            bridgeStatusByInterface: HostBridgeFactsService.statusByInterface(records: records),
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

    @Sendable
    func listBlockDevices(req: Vapor.Request) async throws -> [HostBlockDeviceResponse] {
        let hostDevices = BlockDeviceService.listDevices()
        let disks = try await req.db.read { db in try Disk.fetchAll(db) }
        let claimed = Set(disks.map(\.path))
        return hostDevices.map { dev in
            let busy = claimed.contains(dev.path)
            return HostBlockDeviceResponse(
                path: dev.path,
                name: dev.name,
                sizeBytes: dev.sizeBytes,
                model: dev.model,
                attachable: dev.attachable && !busy,
                excludedReason: busy ? "Already attached as a VM disk" : dev.excludedReason,
            )
        }
    }

    // MARK: - GPU Devices

    @Sendable
    func listGPUDevices(req: Vapor.Request) async throws -> [HostGPUDeviceResponse] {
        let hostDevices = GPUDeviceService.listDevices()
        let allVMs = try await req.db.read { db in try VM.fetchAll(db) }
        return hostDevices.map { hostDeviceResponse(dev: $0, vms: allVMs) }
    }

    @Sendable
    func listPCIDevices(req: Vapor.Request) async throws -> [HostGPUDeviceResponse] {
        let hostDevices = GPUDeviceService.listPCIDevices()
        let allVMs = try await req.db.read { db in try VM.fetchAll(db) }
        return hostDevices.map { hostDeviceResponse(dev: $0, vms: allVMs) }
    }

    private func hostDeviceResponse(dev: HostGPUDevice, vms: [VM]) -> HostGPUDeviceResponse {
        let claim = GPUPassthroughService.claimedBy(host: dev, vms: vms)
        var attachable = dev.attachable && claim == nil
        var reason = dev.excludedReason
        if let claim {
            attachable = false
            reason = reason ?? GPUPassthroughService.claimedMessage(
                workloadName: claim.name, host: dev,
            )
        }
        return HostGPUDeviceResponse(
            id: dev.id,
            pciAddress: dev.pciAddress,
            iommuGroup: dev.iommuGroup,
            vendorId: dev.vendorId,
            deviceId: dev.deviceId,
            pciClass: dev.pciClass,
            name: dev.name,
            driver: dev.driver,
            vfioBound: dev.vfioBound,
            inUseByHost: dev.inUseByHost,
            attachable: attachable,
            excludedReason: reason,
            groupAddresses: dev.groupAddresses,
            guestOllamaPath: dev.guestOllamaPath,
            busy: claim != nil || dev.inUseByHost,
            attachedToVmId: claim?.id,
            claimedByVMId: claim?.id,
            claimedByVMName: claim?.name,
        )
    }
}
