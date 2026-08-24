import Foundation

/// Home routing table: which Device has which model pulled/running (PAS-269).
public enum OllamaHomeMap {
    public static let staleAfter: TimeInterval = 90
    public static let refreshInterval: TimeInterval = 30

    public static func isStale(
        probedAt: String?,
        now: Date = Date(),
        staleAfter: TimeInterval = staleAfter,
    ) -> Bool {
        guard let probedAt, let date = iso8601.date(from: probedAt) else { return true }
        return now.timeIntervalSince(date) > staleAfter
    }

    public static func catalog(
        from snapshots: [OllamaDeviceSnapshot],
        now: Date = Date(),
        staleAfter: TimeInterval = staleAfter,
        refreshedAt: String? = nil,
    ) -> OllamaHomeCatalog {
        var devices: [OllamaDeviceStatus] = []
        var byName: [String: [OllamaModelLocation]] = [:]
        var meta: [String: OllamaLocalModel] = [:]

        for snap in snapshots {
            let stale = isStale(probedAt: snap.probedAt, now: now, staleAfter: staleAfter)
            let live = snap.reachable && !stale
            devices.append(
                OllamaDeviceStatus(
                    hostId: snap.hostId,
                    displayName: snap.displayName,
                    installed: snap.installed,
                    reachable: live,
                    stale: stale || !snap.reachable,
                    binaryPath: snap.binaryPath,
                    installHint: snap.installHint,
                    probedAt: snap.probedAt,
                ),
            )
            guard live else { continue }
            for model in snap.models {
                let key = OllamaModelName.canonical(model.name)
                if meta[key] == nil { meta[key] = model }
                byName[key, default: []].append(
                    OllamaModelLocation(
                        hostId: snap.hostId,
                        displayName: snap.displayName,
                        running: model.running,
                        reachable: true,
                        probedAt: snap.probedAt,
                        size: model.size,
                        sizeVRAM: model.sizeVRAM,
                        digest: model.digest,
                        memoryTotalMB: snap.memoryTotalMB,
                        memoryUsedMB: snap.memoryUsedMB,
                        cpuLoadPercent: snap.cpuLoadPercent,
                    ),
                )
            }
        }

        let models: [OllamaCatalogModel] = byName.keys.sorted().compactMap { key in
            guard let locations = byName[key], let seed = meta[key] else { return nil }
            return OllamaCatalogModel(
                name: seed.name,
                digest: seed.digest,
                size: seed.size,
                sizeVRAM: locations.first(where: \.running)?.sizeVRAM ?? seed.sizeVRAM,
                running: locations.contains(where: \.running),
                locations: locations,
            )
        }

        return OllamaHomeCatalog(
            anyReachable: devices.contains(where: { $0.reachable && !$0.stale }),
            anyInstalled: devices.contains(where: \.installed),
            refreshedAt: refreshedAt,
            models: models,
            devices: devices,
        )
    }

    public static func catalog(
        persisted: OllamaPersistedMap,
        now: Date = Date(),
        staleAfter: TimeInterval = staleAfter,
    ) -> OllamaHomeCatalog {
        catalog(
            from: persisted.devices,
            now: now,
            staleAfter: staleAfter,
            refreshedAt: persisted.refreshedAt,
        )
    }

    /// Completions use the stored map unless the model has no live Device.
    public static func needsProbe(
        model: String,
        catalog: OllamaHomeCatalog?,
        now: Date = Date(),
    ) -> Bool {
        guard let catalog else { return true }
        return OllamaRouter.pick(model: model, catalog: catalog, now: now) == nil
    }
}
