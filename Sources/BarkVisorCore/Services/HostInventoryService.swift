import Foundation

/// Assembles a complete `HostInventory` from platform helpers.
///
/// Callers (capabilities API, diagnostics, future agent API) **project** from this
/// snapshot rather than re-querying `PlatformHost` / `PlatformCapabilities` ad hoc.
public enum HostInventoryService {
    public static let currentSchemaVersion = 1

    /// Build a fresh inventory for this process's host.
    public static func snapshot(
        now: Date = Date(),
        dataDir: URL = Config.dataDir,
        version: String = Config.version,
    ) -> HostInventory {
        let hostname = ProcessInfo.processInfo.hostName
        let arch = PlatformCapabilities.hostArch
        let accelerator = PlatformCapabilities.accelerator

        let interfaces = HostInfoService.listInterfaceSnapshots().map { snap in
            NetworkInterfaceInfo(
                name: snap.name,
                displayName: snap.displayName,
                ipv4: snap.ipAddress.isEmpty ? [] : [snap.ipAddress],
                exists: true,
            )
        }

        let storage = [dataDirStorage(at: dataDir)]

        let features = VirtualizationFeatures(
            bridgedNetworking: PlatformCapabilities.supportsBridgedNetworking,
            managedBridgeDaemon: PlatformCapabilities.supportsManagedBridgeDaemon,
            usbPassthrough: PlatformCapabilities.supportsUSBPassthrough,
            inAppUpdate: PlatformCapabilities.supportsInAppUpdate,
            kvmDevice: kvmDevicePresent(),
            qemuBridgeHelper: qemuBridgeHelperPresent(),
        )

        // Only advertise guest types this host can run natively (PAS-48).
        // Catalog UIs filter by these arches; including both arches made the
        // filter a no-op and offered failing wrong-arch images as runnable.
        let guestTypes = GuestProfiles.profilesCompatible(withHostArch: arch).map {
            GuestTypeSnapshot(
                id: $0.id,
                arch: $0.arch,
                machine: $0.machine,
                osFamily: $0.osFamily,
                qemuBinary: $0.qemuBinaryName,
            )
        }

        return HostInventory(
            schemaVersion: currentSchemaVersion,
            displayName: hostname,
            agent: AgentInfo(version: version),
            platform: PlatformInfo(
                os: PlatformHost.platformName,
                osVersion: PlatformHost.osVersionString,
                arch: arch,
                hostname: hostname,
            ),
            resources: ResourcesInfo(
                cpuCount: PlatformHost.cpuCount,
                memoryTotalMB: PlatformHost.physicalMemoryMB,
                memoryUsedMB: PlatformHost.memoryUsedMB,
                cpuLoadPercent: PlatformHost.cpuLoadPercent,
            ),
            storage: storage,
            networking: NetworkingInfo(interfaces: interfaces),
            virtualization: VirtualizationInfo(
                accelerator: accelerator,
                qemuCPUModel: PlatformCapabilities.qemuCPUModel,
                defaultGuestArch: PlatformCapabilities.defaultGuestArch,
                features: features,
            ),
            guestTypes: guestTypes,
            collectedAt: iso8601.string(from: now),
        )
    }

    // MARK: - Probes

    /// Linux: `/dev/kvm` present. Other platforms: false.
    public static func kvmDevicePresent() -> Bool {
        #if os(Linux)
            FileManager.default.fileExists(atPath: "/dev/kvm")
        #else
            false
        #endif
    }

    /// Linux: setuid helper typically at `/usr/lib/qemu/qemu-bridge-helper` (distro paths vary).
    public static func qemuBridgeHelperPresent() -> Bool {
        #if os(Linux)
            let candidates = [
                "/usr/lib/qemu/qemu-bridge-helper",
                "/usr/libexec/qemu-bridge-helper",
                "/usr/local/libexec/qemu/qemu-bridge-helper",
            ]
            return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
        #else
            false
        #endif
    }

    private static func dataDirStorage(at dataDir: URL) -> StorageEntry {
        let path = dataDir.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path) else {
            return StorageEntry(path: path, totalBytes: nil, freeBytes: nil, kind: "dataDir")
        }
        let total = (attrs[.systemSize] as? NSNumber)?.uint64Value
        let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value
        return StorageEntry(path: path, totalBytes: total, freeBytes: free, kind: "dataDir")
    }
}
