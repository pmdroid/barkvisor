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
        let osName = PlatformHost.platformName
        let vfioFacts = VFIOProbe.live()
        let features = VirtualizationFeatures(
            bridgedNetworking: bridgedNetworkingSupported(
                platformSupports: PlatformCapabilities.supportsBridgedNetworking,
                qemuBridgeHelper: qemuBridgeHelper,
                os: osName,
            ),
            managedBridgeDaemon: PlatformCapabilities.supportsManagedBridgeDaemon,
            usbPassthrough: PlatformCapabilities.supportsUSBPassthrough,
            inAppUpdate: PlatformCapabilities.supportsInAppUpdate,
            kvmDevice: kvmDevicePresent(),
            qemuBridgeHelper: qemuBridgeHelper,
            gpuPassthrough: VFIOProbe.gpuPassthroughSupported(os: osName, facts: vfioFacts),
            vfio: VFIOProbe.vfioSupported(os: osName, facts: vfioFacts),
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
                os: osName,
                osVersion: PlatformHost.osVersionString,
                arch: arch,
                hostname: hostname,
            ),
            resources: liveResources(),
            storage: storage,
            networking: NetworkingInfo(
                interfaces: interfaces,
                tailnet: cachedTailnet(),
            ),
            virtualization: VirtualizationInfo(
                accelerator: accelerator,
                qemuCPUModel: PlatformCapabilities.qemuCPUModel,
                defaultGuestArch: PlatformCapabilities.defaultGuestArch,
                features: features,
                vfioProbe: vfioFacts.inventory,
            ),
            guestTypes: guestTypes,
            collectedAt: iso8601.string(from: now),
        )
    }

    /// Same TTL as `MetricsCollector.systemStatsPollIntervalSeconds` so
    /// Dashboard / VMList 5s polls reuse stable slices instead of rebuilding
    /// the full inventory (interfaces, guest profiles, kvm/qemu-bridge probes).
    public static let metricsSliceTTL = TimeInterval(
        MetricsCollector.systemStatsPollIntervalSeconds,
    )

    /// Fields `HostMetrics` needs. Live CPU/mem; cached hostId + dataDir storage.
    public static func metricsSlice(
        now: Date = Date(),
        dataDir: URL = Config.dataDir,
        hostId: String? = nil,
    ) -> HostMetricsSlice {
        let resolvedHostId = hostId ?? sliceCache.hostId(for: dataDir) {
            HostIdentity.loadOrCreate(dataDir: dataDir).uuidString
        }
        let storage = sliceCache.storage(for: dataDir, now: now, ttl: metricsSliceTTL) {
            [dataDirStorage(at: dataDir)]
        }
        return HostMetricsSlice(
            hostId: resolvedHostId,
            collectedAt: iso8601.string(from: now),
            resources: liveResources(),
            storage: storage,
        )
    }

    static func resetMetricsSliceCache() {
        sliceCache.reset()
    }

    /// Last-known tailnet for request paths. A cold `detect()` can
    /// `PlatformProcess.run` + `Thread.sleep`; refresh that off-request.
    private static func cachedTailnet() -> TailnetInfo? {
        TailscaleProbe.refreshOffRequest()
        return TailscaleProbe.lastKnown()
    }

    // MARK: - Probes

    /// Placement / health flags from the live probe (PAS-274 gpu/vfio included).
    public static func featureSummary() -> HomeDeviceFeatureSummary {
        let osName = PlatformHost.platformName
        let qemuBridgeHelper = qemuBridgeHelperPresent()
        let vfioFacts = VFIOProbe.live()
        return HomeDeviceFeatureSummary(
            kvmDevice: kvmDevicePresent(),
            bridgedNetworking: bridgedNetworkingSupported(
                platformSupports: PlatformCapabilities.supportsBridgedNetworking,
                qemuBridgeHelper: qemuBridgeHelper,
                os: osName,
            ),
            usbPassthrough: PlatformCapabilities.supportsUSBPassthrough,
            gpuPassthrough: VFIOProbe.gpuPassthroughSupported(os: osName, facts: vfioFacts),
            vfio: VFIOProbe.vfioSupported(os: osName, facts: vfioFacts),
        )
    }

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
            HostBridgeFactsService.qemuBridgeHelperCandidates.contains {
                FileManager.default.isExecutableFile(atPath: $0)
            }
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

    private static let sliceCache = MetricsSliceCache()

    private static func liveResources() -> ResourcesInfo {
        ResourcesInfo(
            cpuCount: PlatformHost.cpuCount,
            memoryTotalMB: PlatformHost.physicalMemoryMB,
            memoryUsedMB: PlatformHost.memoryUsedMB,
            cpuLoadPercent: PlatformHost.cpuLoadPercent,
        )
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

/// Process-lifetime hostId + poll-interval storage for `metricsSlice`.
private final class MetricsSliceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var hostIds: [String: String] = [:]
    private var storage: [String: (entries: [StorageEntry], expiresAt: Date)] = [:]

    func hostId(for dataDir: URL, load: () -> String) -> String {
        let key = dataDir.path
        lock.lock()
        if let cached = hostIds[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = load()
        lock.lock()
        hostIds[key] = value
        lock.unlock()
        return value
    }

    func storage(
        for dataDir: URL,
        now: Date,
        ttl: TimeInterval,
        load: () -> [StorageEntry],
    ) -> [StorageEntry] {
        let key = dataDir.path
        lock.lock()
        if let cached = storage[key], cached.expiresAt > now {
            let entries = cached.entries
            lock.unlock()
            return entries
        }
        lock.unlock()
        let entries = load()
        lock.lock()
        storage[key] = (entries, now.addingTimeInterval(ttl))
        lock.unlock()
        return entries
    }

    func reset() {
        lock.lock()
        hostIds.removeAll()
        storage.removeAll()
        lock.unlock()
    }
}
