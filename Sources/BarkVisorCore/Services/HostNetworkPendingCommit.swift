import Foundation

/// Post-apply confirmation window before host network changes are permanent.
public struct HostNetworkPendingCommit: Codable, Sendable, Equatable {
    public var target: String
    public var commitDeadline: Date
    public var rollbackSeconds: Int
    public var createdBridge: Bool
    public var netplanPid: Int32?

    public init(
        target: String,
        commitDeadline: Date,
        rollbackSeconds: Int,
        createdBridge: Bool = false,
        netplanPid: Int32? = nil,
    ) {
        self.target = target
        self.commitDeadline = commitDeadline
        self.rollbackSeconds = rollbackSeconds
        self.createdBridge = createdBridge
        self.netplanPid = netplanPid
    }

    enum CodingKeys: String, CodingKey {
        case target, commitDeadline, rollbackSeconds, createdBridge, netplanPid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        commitDeadline = try c.decode(Date.self, forKey: .commitDeadline)
        rollbackSeconds = try c.decode(Int.self, forKey: .rollbackSeconds)
        createdBridge = try c.decodeIfPresent(Bool.self, forKey: .createdBridge) ?? false
        netplanPid = try c.decodeIfPresent(Int32.self, forKey: .netplanPid)
    }

    public var expired: Bool {
        Date() >= commitDeadline
    }

    /// API-facing slice (no internal fields).
    public var publicInfo: HostNetworkPendingCommitInfo {
        HostNetworkPendingCommitInfo(
            target: target,
            commitDeadline: commitDeadline,
            rollbackSeconds: rollbackSeconds,
            createdBridge: createdBridge,
        )
    }
}

public struct HostNetworkPendingCommitInfo: Codable, Sendable, Equatable {
    public var target: String
    public var commitDeadline: Date
    public var rollbackSeconds: Int
    public var createdBridge: Bool

    public init(target: String, commitDeadline: Date, rollbackSeconds: Int, createdBridge: Bool = false) {
        self.target = target
        self.commitDeadline = commitDeadline
        self.rollbackSeconds = rollbackSeconds
        self.createdBridge = createdBridge
    }

    enum CodingKeys: String, CodingKey {
        case target, commitDeadline, rollbackSeconds, createdBridge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        commitDeadline = try c.decode(Date.self, forKey: .commitDeadline)
        rollbackSeconds = try c.decode(Int.self, forKey: .rollbackSeconds)
        createdBridge = try c.decodeIfPresent(Bool.self, forKey: .createdBridge) ?? false
    }
}

public enum HostNetworkPendingCommitService {
    public static let rollbackSeconds = LinuxHostBridgeApply.rollbackSeconds

    public static func linuxPendingPath(bridge: String, dataDir: URL = Config.dataDir) -> String {
        dataDir.appendingPathComponent("host-network", isDirectory: true)
            .appendingPathComponent("\(bridge)-pending.json").path
    }

    public static func macPendingURL(device: String, dataDir: URL = Config.dataDir) -> URL {
        dataDir
            .appendingPathComponent("host-network", isDirectory: true)
            .appendingPathComponent("\(device)-pending.json")
    }

    public static func readLinux(bridge: String) -> HostNetworkPendingCommit? {
        let path = linuxPendingPath(bridge: bridge)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(HostNetworkPendingCommit.self, from: data)
    }

    public static func blockingPending(
        target: String,
        existing: [HostNetworkPendingCommit],
    ) -> HostNetworkPendingCommit? {
        existing.first { $0.target != target && !$0.expired }
    }

    public static func listLinuxPending(dataDir: URL = Config.dataDir) -> [HostNetworkPendingCommit] {
        let dir = dataDir.appendingPathComponent("host-network", isDirectory: true).path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var result: [HostNetworkPendingCommit] = []
        for name in names where name.hasSuffix("-pending.json") {
            let path = "\(dir)/\(name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let pending = try? JSONDecoder().decode(HostNetworkPendingCommit.self, from: data)
            else { continue }
            result.append(pending)
        }
        return result
    }

    public static func writeLinux(_ pending: HostNetworkPendingCommit) throws {
        if let other = blockingPending(target: pending.target, existing: listLinuxPending()) {
            throw BarkVisorError.conflict(
                "A host network apply is already pending for \(other.target). Keep or Revert it first.",
            )
        }
        let path = linuxPendingPath(bridge: pending.target)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            atPath: "/run/barkvisor",
            withIntermediateDirectories: true,
        )
        let data = try JSONEncoder().encode(pending)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func clearLinux(bridge: String) {
        try? FileManager.default.removeItem(atPath: linuxPendingPath(bridge: bridge))
    }

    #if os(macOS)
        public static func readMac(device: String) -> HostNetworkPendingCommit? {
            let url = macPendingURL(device: device)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(HostNetworkPendingCommit.self, from: data)
        }

        public static func writeMac(_ pending: HostNetworkPendingCommit) throws {
            let url = macPendingURL(device: pending.target)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(pending)
            try data.write(to: url, options: .atomic)
        }

        public static func clearMac(device: String) {
            try? FileManager.default.removeItem(at: macPendingURL(device: device))
        }
    #endif

    public static func listMacPending(dataDir: URL = Config.dataDir) -> [HostNetworkPendingCommit] {
        let dir = dataDir.appendingPathComponent("host-network", isDirectory: true).path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var result: [HostNetworkPendingCommit] = []
        for name in names where name.hasSuffix("-pending.json") {
            let path = "\(dir)/\(name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let pending = try? JSONDecoder().decode(HostNetworkPendingCommit.self, from: data)
            else { continue }
            result.append(pending)
        }
        return result
    }

    public static func stampExists(_ target: String) -> Bool {
        FileManager.default.fileExists(atPath: LinuxHostBridgeApply.commitStampPath(bridge: target))
    }

    public static func activePending() -> HostNetworkPendingCommit? {
        #if os(Linux)
            return listLinuxPending().first { !stampExists($0.target) }
        #elseif os(macOS)
            return listMacPending().first { !stampExists($0.target) }
        #else
            return nil
        #endif
    }

    public static func makePending(
        target: String,
        createdBridge: Bool = false,
        netplanPid: Int32? = nil,
    ) -> HostNetworkPendingCommit {
        HostNetworkPendingCommit(
            target: target,
            commitDeadline: Date().addingTimeInterval(TimeInterval(rollbackSeconds)),
            rollbackSeconds: rollbackSeconds,
            createdBridge: createdBridge,
            netplanPid: netplanPid,
        )
    }
}
