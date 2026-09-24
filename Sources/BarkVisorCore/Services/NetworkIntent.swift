import Foundation

public enum IPFamily: String, Codable, Sendable, Equatable {
    case ipv4
    case ipv6
}

public enum PortExposure: String, Codable, Sendable, Equatable {
    case loopback
    case interface
    case wildcard
}

public struct PortPublication: Codable, Equatable, Sendable {
    public var family: IPFamily
    public var bindAddress: String
    public var proto: String
    public var publishedPort: Int
    public var targetPort: Int
    public var exposure: PortExposure

    public init(
        family: IPFamily,
        bindAddress: String,
        proto: String,
        publishedPort: Int,
        targetPort: Int,
        exposure: PortExposure,
    ) {
        self.family = family
        self.bindAddress = bindAddress
        self.proto = proto
        self.publishedPort = publishedPort
        self.targetPort = targetPort
        self.exposure = exposure
    }
}

public struct NetworkIntent: Equatable, Sendable {
    public var publications: [PortPublication]
    public var upstreamResolver: String?
    public var guestDNS: String?

    public init(
        publications: [PortPublication],
        upstreamResolver: String? = nil,
        guestDNS: String? = nil,
    ) {
        self.publications = publications
        self.upstreamResolver = upstreamResolver
        self.guestDNS = guestDNS
    }

    public static func publication(
        bindAddress: String,
        proto: String,
        publishedPort: Int,
        targetPort: Int,
    ) throws -> PortPublication {
        let bind = NetworkIntentBinding.normalize(bindAddress)
        guard !bind.isEmpty else {
            throw BarkVisorError.badRequest("Published port is missing a bind address")
        }
        let family = NetworkIntentBinding.family(of: bind)
        let exposure = NetworkIntentBinding.exposure(of: bind, family: family)
        let transport = proto.lowercased()
        guard transport == "tcp" || transport == "udp" else {
            throw BarkVisorError.badRequest("Port protocol must be tcp or udp")
        }
        guard (1 ... 65_535).contains(publishedPort), (1 ... 65_535).contains(targetPort) else {
            throw BarkVisorError.badRequest("Port numbers must be between 1 and 65535")
        }
        return PortPublication(
            family: family,
            bindAddress: bind,
            proto: transport,
            publishedPort: publishedPort,
            targetPort: targetPort,
            exposure: exposure,
        )
    }
}

public struct ResolvedNetworkPlan: Equatable, Sendable {
    public var runtime: String
    public var publications: [PortPublication]
    public var guestDNS: String?
    public var upstreamResolvers: [String]

    public init(
        runtime: String,
        publications: [PortPublication],
        guestDNS: String? = nil,
        upstreamResolvers: [String] = [],
    ) {
        self.runtime = runtime
        self.publications = publications
        self.guestDNS = guestDNS
        self.upstreamResolvers = upstreamResolvers
    }
}

public struct ObservedPortBinding: Equatable, Sendable {
    public var hostIP: String
    public var hostPort: Int
    public var targetPort: Int
    public var proto: String

    public init(hostIP: String, hostPort: Int, targetPort: Int, proto: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.targetPort = targetPort
        self.proto = proto
    }
}

public enum NetworkRuntime: String, Sendable {
    case qemu
    case compose
}

public enum NetworkIntentResolver {
    public static func resolve(
        _ intent: NetworkIntent,
        runtime: NetworkRuntime,
        mode: NetworkMode,
    ) throws -> ResolvedNetworkPlan {
        for pair in intent.publications.indices {
            for other in intent.publications.indices where other > pair {
                if NetworkIntentBinding.overlaps(intent.publications[pair], intent.publications[other]) {
                    let port = intent.publications[pair]
                    throw BarkVisorError.portInUse(
                        "Host port \(port.publishedPort)/\(port.proto) is claimed more than once",
                    )
                }
            }
        }
        switch runtime {
        case .qemu:
            if !intent.publications.isEmpty, mode != .nat {
                throw BarkVisorError.invalidPortForward(
                    "Port forwards require NAT. Mode '\(mode.rawValue)' does not support hostfwd.",
                )
            }
            if intent.upstreamResolver != nil {
                throw BarkVisorError.badRequest(
                    "QEMU cannot choose an upstream resolver. Guest-visible DNS is a separate address.",
                )
            }
            if let guest = intent.guestDNS {
                try NetworkIntentBinding.requireIPv4(guest, label: "Guest-visible DNS")
            }
            return ResolvedNetworkPlan(
                runtime: runtime.rawValue,
                publications: intent.publications,
                guestDNS: intent.guestDNS,
                upstreamResolvers: [],
            )
        case .compose:
            if intent.guestDNS != nil {
                throw BarkVisorError.badRequest(
                    "Compose has no guest-visible virtual DNS address. Set an upstream resolver instead.",
                )
            }
            var upstream: [String] = []
            if let resolver = intent.upstreamResolver {
                try NetworkIntentBinding.requireIP(resolver, label: "Upstream resolver")
                upstream = [NetworkIntentBinding.normalize(resolver)]
            }
            return ResolvedNetworkPlan(
                runtime: runtime.rawValue,
                publications: intent.publications,
                guestDNS: nil,
                upstreamResolvers: upstream,
            )
        }
    }

    public static func qemuHostfwd(_ publication: PortPublication) -> String {
        let host: String
        if publication.exposure == .wildcard, publication.family == .ipv4 {
            host = ""
        } else if publication.family == .ipv6 {
            host = "[\(publication.bindAddress)]"
        } else {
            host = publication.bindAddress
        }
        return "hostfwd=\(publication.proto):\(host):\(publication.publishedPort)-:\(publication.targetPort)"
    }

    public static func mismatches(
        planned: [PortPublication],
        observed: [ObservedPortBinding],
        allowWildcard: Bool,
    ) -> [String] {
        var problems: [String] = []
        for port in planned {
            let rows = observed.filter {
                $0.hostPort == port.publishedPort && $0.proto.lowercased() == port.proto
                    && $0.targetPort == port.targetPort
            }
            guard let row = rows.first(where: {
                NetworkIntentBinding.hostsMatch(
                    planned: port.bindAddress,
                    observed: $0.hostIP,
                    allowWildcard: allowWildcard,
                )
            }) ?? rows.first else {
                problems.append("docker inspect missing \(port.publishedPort)/\(port.proto)")
                continue
            }
            if !NetworkIntentBinding.hostsMatch(
                planned: port.bindAddress,
                observed: row.hostIP,
                allowWildcard: allowWildcard,
            ) {
                problems.append(
                    "docker inspect \(port.publishedPort)/\(port.proto) bound \(row.hostIP) but plan is \(port.bindAddress)",
                )
            }
        }
        return problems
    }
}

public enum NetworkIntentBinding {
    public static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    public static func family(of address: String) -> IPFamily {
        normalize(address).contains(":") ? .ipv6 : .ipv4
    }

    public static func isWildcard(_ address: String) -> Bool {
        switch normalize(address) {
        case "", "0.0.0.0", "::", "::0", "https://example.net/id/garnet", "*":
            return true
        default:
            return false
        }
    }

    public static func exposure(of address: String, family: IPFamily) -> PortExposure {
        let bind = normalize(address)
        if isWildcard(bind) { return .wildcard }
        if family == .ipv4, bind == "127.0.0.1" { return .loopback }
        if family == .ipv6, bind == "::1" { return .loopback }
        return .interface
    }

    public static func overlaps(_ lhs: PortPublication, _ rhs: PortPublication) -> Bool {
        guard lhs.publishedPort == rhs.publishedPort, lhs.proto == rhs.proto else { return false }
        if lhs.exposure == .wildcard, lhs.family == .ipv6 { return true }
        if rhs.exposure == .wildcard, rhs.family == .ipv6 { return true }
        if lhs.family != rhs.family { return false }
        if lhs.exposure == .wildcard || rhs.exposure == .wildcard { return true }
        return lhs.bindAddress == rhs.bindAddress
    }

    public static func hostsMatch(planned: String, observed: String, allowWildcard: Bool) -> Bool {
        let plan = normalize(planned)
        let seen = normalize(observed)
        if plan == seen { return true }
        if seen.isEmpty, isWildcard(plan) { return true }
        if allowWildcard, isWildcard(seen), family(of: plan) == family(of: seen.isEmpty ? plan : seen) {
            return true
        }
        return false
    }

    public static func requireIPv4(_ raw: String, label: String) throws {
        let parts = normalize(raw).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            guard let value = Int(part), (0 ... 255).contains(value) else { return false }
            return String(value) == part
        }) else {
            throw BarkVisorError.badRequest("\(label) must be an IPv4 address")
        }
    }

    public static func requireIP(_ raw: String, label: String) throws {
        let bind = normalize(raw)
        if family(of: bind) == .ipv4 {
            try requireIPv4(bind, label: label)
            return
        }
        guard bind.contains(":"), !bind.contains(" ") else {
            throw BarkVisorError.badRequest("\(label) must be an IP address")
        }
    }
}

public enum PendingNetworkUsePolicy {
    public static func attachmentConfirmsPending() -> Bool { false }

    public static func usableWhileUnconfirmed() -> Bool { false }

    public static func expiredUnconfirmedReverts() -> Bool { true }

    public enum ExpiryAction: Equatable, Sendable {
        case keep
        case revert
    }

    public static func expiryAction(attachedWorkloads: Int) -> ExpiryAction {
        if attachmentConfirmsPending(), attachedWorkloads > 0 { return .keep }
        return .revert
    }
}

public struct HostNetworkSnapshot: Codable, Equatable, Sendable {
    public var files: [String: String]
    public var absentPaths: [String]
    public var aclContents: String?

    public init(
        files: [String: String] = [:],
        absentPaths: [String] = [],
        aclContents: String? = nil,
    ) {
        self.files = files
        self.absentPaths = absentPaths
        self.aclContents = aclContents
    }
}

public enum HostNetworkRecoveryPhase {
    public static let prepared = "prepared"
    public static let mutating = "mutating"
    public static let awaitingConfirmation = "awaitingConfirmation"
    public static let reverting = "reverting"
    public static let confirmed = "confirmed"
}

public struct HostNetworkRecoveryRecord: Codable, Equatable, Sendable {
    public var operationId: String
    public var generation: Int
    public var target: String
    public var phase: String
    public var deadline: Date
    public var snapshot: HostNetworkSnapshot

    public init(
        operationId: String,
        generation: Int,
        target: String,
        phase: String,
        deadline: Date,
        snapshot: HostNetworkSnapshot,
    ) {
        self.operationId = operationId
        self.generation = generation
        self.target = target
        self.phase = phase
        self.deadline = deadline
        self.snapshot = snapshot
    }
}

public enum HostNetworkRecovery {
    public static func capture(paths: [String], aclContents: String? = nil) -> HostNetworkSnapshot {
        var files: [String: String] = [:]
        var absent: [String] = []
        for path in paths {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                files[path] = text
            } else {
                absent.append(path)
            }
        }
        return HostNetworkSnapshot(files: files, absentPaths: absent, aclContents: aclContents)
    }

    public static func begin(
        operationId: String,
        generation: Int,
        target: String,
        snapshot: HostNetworkSnapshot,
        deadline: Date,
        dataDir: URL = Config.dataDir,
    ) throws -> HostNetworkRecoveryRecord {
        try requireOperationId(operationId)
        let record = HostNetworkRecoveryRecord(
            operationId: operationId,
            generation: generation,
            target: target,
            phase: HostNetworkRecoveryPhase.mutating,
            deadline: deadline,
            snapshot: snapshot,
        )
        try save(record, dataDir: dataDir)
        return record
    }

    public static func mark(
        _ operationId: String,
        phase: String,
        dataDir: URL = Config.dataDir,
    ) throws {
        guard var record = load(operationId: operationId, dataDir: dataDir) else {
            throw BarkVisorError.notFound("No host network recovery record for \(operationId)")
        }
        record.phase = phase
        try save(record, dataDir: dataDir)
    }

    public static func load(operationId: String, dataDir: URL = Config.dataDir) -> HostNetworkRecoveryRecord? {
        guard let url = try? recordURL(operationId: operationId, dataDir: dataDir) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HostNetworkRecoveryRecord.self, from: data)
    }

    public static func list(dataDir: URL = Config.dataDir) -> [HostNetworkRecoveryRecord] {
        let dir = dataDir.appendingPathComponent("host-network/recovery", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(HostNetworkRecoveryRecord.self, from: data)
        }
    }

    public static func requireConfirmation(
        pending: HostNetworkPendingCommit,
        requestedOperationId: String?,
        requestedGeneration: Int?,
        authorized: Bool,
        now: Date = Date(),
        dataDir: URL = Config.dataDir,
    ) throws {
        if !authorized {
            throw BarkVisorError.unauthorized("Host network confirmation is not authorized")
        }
        if now >= pending.commitDeadline {
            throw BarkVisorError.badRequest(
                "Pending apply expired. Network may have auto-reverted — run Revert to clean up.",
            )
        }
        guard let storedOperation = pending.operationId else { return }
        guard let record = load(operationId: storedOperation, dataDir: dataDir) else {
            throw BarkVisorError.conflict(
                "Host network recovery record for \(storedOperation) is missing",
            )
        }
        if record.phase == HostNetworkRecoveryPhase.reverting {
            throw BarkVisorError.conflict("Host network operation \(storedOperation) is already reverting")
        }
        if record.phase == HostNetworkRecoveryPhase.confirmed { return }
        guard requestedOperationId == storedOperation else {
            throw BarkVisorError.conflict(
                "Confirmation does not match pending host network operation \(storedOperation)",
            )
        }
        guard requestedGeneration == record.generation else {
            throw BarkVisorError.conflict(
                "Stale confirmation cannot commit host network operation \(storedOperation)",
            )
        }
        if now >= record.deadline {
            throw BarkVisorError.badRequest(
                "Pending apply expired. Network may have auto-reverted — run Revert to clean up.",
            )
        }
    }

    public static func restore(_ snapshot: HostNetworkSnapshot) throws {
        let fm = FileManager.default
        for (path, body) in snapshot.files {
            let url = URL(fileURLWithPath: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        for path in snapshot.absentPaths where fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }

    @discardableResult
    public static func revertExpired(
        dataDir: URL = Config.dataDir,
        now: Date = Date(),
    ) throws -> [String] {
        guard PendingNetworkUsePolicy.expiredUnconfirmedReverts() else { return [] }
        var reverted: [String] = []
        for record in list(dataDir: dataDir) {
            guard record.phase != HostNetworkRecoveryPhase.confirmed else { continue }
            guard now >= record.deadline else { continue }
            try restore(record.snapshot)
            var next = record
            next.phase = HostNetworkRecoveryPhase.reverting
            try save(next, dataDir: dataDir)
            reverted.append(record.operationId)
        }
        return reverted
    }

    public static func save(_ record: HostNetworkRecoveryRecord, dataDir: URL = Config.dataDir) throws {
        let url = try recordURL(operationId: record.operationId, dataDir: dataDir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    private static func recordURL(operationId: String, dataDir: URL) throws -> URL {
        try requireOperationId(operationId)
        return dataDir
            .appendingPathComponent("host-network/recovery", isDirectory: true)
            .appendingPathComponent("\(operationId).json")
    }

    private static func requireOperationId(_ operationId: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !operationId.isEmpty, operationId.count <= 80,
              operationId.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw BarkVisorError.badRequest("Host network operation id is not a single path segment")
        }
    }
}
