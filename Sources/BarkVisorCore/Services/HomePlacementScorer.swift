import Foundation

/// One Home recommender (PAS-44 + PAS-43). Hard filters, then CPU/mem rank.
///
/// Does not start or move workloads. A down peer is ineligible; this Device
/// still ranks (PAS-47 / PAS-90).
public enum HomePlacementScorer {
    public static let hardKind = "hard"
    public static let softKind = "soft"

    public static let offlineCode = "offline"
    public static let archMismatchCode = "arch_mismatch"
    public static let featureMissingCode = "feature_missing"
    public static let memoryCode = "memory"
    public static let archMatchCode = "arch_match"
    public static let headroomCode = "headroom"

    public static func score(
        request: HomePlacementScoreRequest,
        devices: [HomeDeviceHealthSnapshot],
    ) -> HomePlacementScoreResponse {
        let evaluated = devices.map { evaluate(request: request, device: $0) }
        let ordered = evaluated.sorted(by: rankBefore)
        let recommendedHostId = ordered.first(where: \.eligible)?.hostId
        let candidates = ordered.enumerated().map { index, row in
            HomePlacementCandidate(
                hostId: row.hostId,
                displayName: row.displayName,
                role: row.role,
                eligible: row.eligible,
                recommended: row.hostId == recommendedHostId,
                rank: index + 1,
                score: row.score,
                reasons: row.reasons,
            )
        }
        return HomePlacementScoreResponse(
            recommendedHostId: recommendedHostId,
            candidates: candidates,
        )
    }

    static func evaluate(
        request: HomePlacementScoreRequest,
        device: HomeDeviceHealthSnapshot,
    ) -> Draft {
        var reasons: [HomePlacementReason] = []
        if !isReachable(device) {
            reasons.append(.hard(offlineCode, device.reachabilityError ?? "Device is unreachable."))
            return Draft(device: device, eligible: false, score: 0, reasons: reasons)
        }

        let hostArch = device.platform.map { PlatformCapabilities.normalizedArch($0.arch) } ?? ""
        let wantArches = request.declaredArchitectures
        if !wantArches.isEmpty {
            if hostArch.isEmpty {
                reasons.append(.hard(
                    archMismatchCode,
                    "Device architecture is unknown; cannot confirm \(wantArches.joined(separator: ", ")).",
                ))
            } else if !TemplateArchitecture.supports(architectures: wantArches, arch: hostArch) {
                let listed = wantArches.joined(separator: ", ")
                reasons.append(.hard(
                    archMismatchCode,
                    "Architecture (\(listed)) is not compatible with this Device (\(hostArch)).",
                ))
            } else {
                reasons.append(.soft(archMatchCode, "Architecture matches (\(hostArch))."))
            }
        }

        if !request.requiredFeatures.isEmpty {
            guard let features = device.features else {
                reasons.append(.hard(
                    featureMissingCode,
                    "This Device did not report kvm, bridged, or USB features.",
                ))
                return finish(device: device, reasons: reasons)
            }
            for feature in request.requiredFeatures where !features.supports(feature) {
                let name = HomeDeviceFeatureSummary.canonicalFeature(feature)
                reasons.append(.hard(
                    featureMissingCode,
                    "This Device is missing required feature \(name).",
                ))
            }
        }

        let memoryFloor = max(request.minMemoryMB ?? 0, request.requestedMemoryMB ?? 0)
        let free = device.resources?.freeMemoryMB
        if memoryFloor > 0 {
            guard let free else {
                reasons.append(.hard(
                    memoryCode,
                    "Needs at least \(memoryFloor) MB free memory; this Device did not report memory.",
                ))
                return finish(device: device, reasons: reasons)
            }
            if free < memoryFloor {
                reasons.append(.hard(
                    memoryCode,
                    "Needs at least \(memoryFloor) MB free memory; this Device has \(free) MB free.",
                ))
            }
        }

        if reasons.contains(where: { $0.kind == hardKind }) {
            return finish(device: device, reasons: reasons)
        }

        let score = headroomScore(resources: device.resources)
        reasons.append(.soft(headroomCode, headroomMessage(resources: device.resources)))
        return Draft(device: device, eligible: true, score: score, reasons: reasons)
    }

    public static func memoryFloor(request: HomePlacementScoreRequest) -> Int {
        max(request.minMemoryMB ?? 0, request.requestedMemoryMB ?? 0)
    }

    static func isReachable(_ device: HomeDeviceHealthSnapshot) -> Bool {
        device.role == "self" || device.reachability == HomeDeviceHealthAggregator.ok
    }

    static func headroomScore(resources: HomeDeviceResourceSummary?) -> Int {
        let memPart: Double =
            if let total = resources?.memoryTotalMB, total > 0, let free = resources?.freeMemoryMB {
                min(max(Double(free) / Double(total), 0), 1)
            } else {
                0.5
            }
        let cpuPart: Double =
            if let load = resources?.cpuLoadPercent {
                1 - min(max(load, 0), 100) / 100
            } else {
                0.5
            }
        return Int((memPart * 60 + cpuPart * 40).rounded())
    }

    static func headroomMessage(resources: HomeDeviceResourceSummary?) -> String {
        let free = resources?.freeMemoryMB
        let load = resources?.cpuLoadPercent
        switch (free, load) {
        case let (free?, load?):
            return "\(free) MB free memory, \(formatLoad(load))% CPU load."
        case let (free?, nil):
            return "\(free) MB free memory."
        case let (nil, load?):
            return "\(formatLoad(load))% CPU load."
        default:
            return "Resource headroom is unknown."
        }
    }

    static func formatLoad(_ load: Double) -> String {
        if load == load.rounded() {
            return String(Int(load.rounded()))
        }
        return String(format: "%.1f", load)
    }

    static func rankBefore(_ lhs: Draft, _ rhs: Draft) -> Bool {
        if lhs.eligible != rhs.eligible { return lhs.eligible && !rhs.eligible }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let leftFree = lhs.freeMemoryMB ?? -1
        let rightFree = rhs.freeMemoryMB ?? -1
        if leftFree != rightFree { return leftFree > rightFree }
        let leftLoad = lhs.cpuLoadPercent ?? 100
        let rightLoad = rhs.cpuLoadPercent ?? 100
        if leftLoad != rightLoad { return leftLoad < rightLoad }
        return lhs.hostId < rhs.hostId
    }

    static func finish(device: HomeDeviceHealthSnapshot, reasons: [HomePlacementReason]) -> Draft {
        Draft(device: device, eligible: !reasons.contains { $0.kind == hardKind }, score: 0, reasons: reasons)
    }

    struct Draft {
        var hostId: String
        var displayName: String?
        var role: String
        var eligible: Bool
        var score: Int
        var reasons: [HomePlacementReason]
        var freeMemoryMB: Int?
        var cpuLoadPercent: Double?

        init(
            device: HomeDeviceHealthSnapshot,
            eligible: Bool,
            score: Int,
            reasons: [HomePlacementReason],
        ) {
            hostId = device.hostId
            displayName = device.displayName
            role = device.role
            self.eligible = eligible
            self.score = score
            self.reasons = reasons
            freeMemoryMB = device.resources?.freeMemoryMB
            cpuLoadPercent = device.resources?.cpuLoadPercent
        }
    }
}
