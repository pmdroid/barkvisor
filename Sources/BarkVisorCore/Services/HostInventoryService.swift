import Foundation

/// Assembles a complete `HostInventory` from platform helpers.
///
/// Callers (capabilities API, diagnostics, `/api/agent/inventory`) **project**
/// from this snapshot rather than re-querying `PlatformHost` / `PlatformCapabilities` ad hoc.
public enum HostInventoryService {
    public static let currentSchemaVersion = 1

    /// Build a fresh inventory for this process's host.
    ///
    /// `hostId` defaults to the durable UUID at `dataDir/host-id`. Pass an
    /// explicit value in tests to avoid touching the real data directory.
    public static func snapshot(
        now: Date = Date(),
        dataDir: URL = Config.dataDir,
        version: String = Config.version,
        hostId: String? = nil,
    ) -> HostInventory {
        let resolvedHostId = hostId ?? HostIdentity.loadOrCreate(dataDir: dataDir).uuidString
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

        let qemuBridgeHelper = qemuBridgeHelperPresent()
        let features = VirtualizationFeatures(
            bridgedNetworking: bridgedNetworkingSupported(
                platformSupports: PlatformCapabilities.supportsBridgedNetworking,
                qemuBridgeHelper: qemuBridgeHelper,
                os: PlatformHost.platformName,
            ),
            managedBridgeDaemon: PlatformCapabilities.supportsManagedBridgeDaemon,
            usbPassthrough: PlatformCapabilities.supportsUSBPassthrough,
            inAppUpdate: PlatformCapabilities.supportsInAppUpdate,
            kvmDevice: kvmDevicePresent(),
            qemuBridgeHelper: qemuBridgeHelper,
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
            hostId: resolvedHostId,
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

    /// Product flag for inventory / capabilities.
    ///
    /// Compile-time `PlatformCapabilities.supportsBridgedNetworking` is always true on
    /// Linux; actual `-netdev bridge` attach also needs qemu-bridge-helper.
    public static func bridgedNetworkingSupported(
        platformSupports: Bool,
        qemuBridgeHelper: Bool,
        os: String,
    ) -> Bool {
        if os.caseInsensitiveCompare("Linux") == .orderedSame {
            return platformSupports && qemuBridgeHelper
        }
        return platformSupports
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
