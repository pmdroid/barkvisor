import Foundation

/// Pick one Device for a completion. Never spray every Device (PAS-269).
public enum OllamaRouter {
    public static func locations(
        for model: String,
        in catalog: OllamaHomeCatalog,
    ) -> [OllamaModelLocation] {
        catalog.models.first { OllamaModelName.matches(model, available: $0.name) }?.locations ?? []
    }

    public static func pick(
        model: String,
        locations: [OllamaModelLocation],
        now: Date = Date(),
        staleAfter: TimeInterval = OllamaHomeMap.staleAfter,
    ) -> OllamaModelLocation? {
        let matching = locations.filter { location in
            location.reachable && !OllamaHomeMap.isStale(probedAt: location.probedAt, now: now, staleAfter: staleAfter)
        }
        guard !matching.isEmpty else { return nil }

        let running = matching.filter(\.running)
        let pool = running.isEmpty ? matching : running
        return pool.min(by: healthier)
    }

    public static func pick(
        model: String,
        catalog: OllamaHomeCatalog,
        now: Date = Date(),
        staleAfter: TimeInterval = OllamaHomeMap.staleAfter,
    ) -> OllamaModelLocation? {
        pick(
            model: model,
            locations: locations(for: model, in: catalog),
            now: now,
            staleAfter: staleAfter,
        )
    }

    /// Higher free memory, then lower CPU load. Resource fields come from the snapshot, not this host.
    static func healthier(_ lhs: OllamaModelLocation, _ rhs: OllamaModelLocation) -> Bool {
        let leftFree = lhs.freeMemoryMB ?? -1
        let rightFree = rhs.freeMemoryMB ?? -1
        if leftFree != rightFree { return leftFree > rightFree }
        let leftCPU = lhs.cpuLoadPercent ?? Double.greatestFiniteMagnitude
        let rightCPU = rhs.cpuLoadPercent ?? Double.greatestFiniteMagnitude
        if leftCPU != rightCPU { return leftCPU < rightCPU }
        return lhs.hostId < rhs.hostId
    }
}
