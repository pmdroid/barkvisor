import Foundation

public enum MacHostBridgeApplyLive {
    public static func run(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe? = nil,
        mutator: (any MacHostNetworkMutating)? = nil,
    ) throws -> MacHostBridgeApplyResult {
        try PlatformCapabilities.requireHostMutation()
        let resolved: MacHostBridgeApplyProbe
        if let probe {
            resolved = probe
        } else {
            #if os(macOS)
                resolved = MacHostBridgeApply.liveProbe(
                    service: request.service,
                    nic: request.nic,
                )
            #else
                throw BarkVisorError.forbidden("macOS host-bridge apply runs on a macOS Device.")
            #endif
        }
        var plan = MacHostBridgeApply.evaluate(request: request, probe: resolved)
        guard plan.success, !plan.needsConfirm, !plan.refused else {
            return plan
        }
        if request.action == .check || request.action == .dryRun {
            return plan
        }
        #if os(macOS)
            let writer: any MacHostNetworkMutating = mutator ?? LiveMacHostNetworkMutator()
        #else
            guard let writer = mutator else {
                throw BarkVisorError.forbidden("macOS host-bridge apply runs on a macOS Device.")
            }
        #endif
        try writer.apply(request: request, probe: resolved, plan: plan)
        plan.applied = true
        plan.message = request.action == .revert
            ? "Reverted Device address on this Device."
            : "Applied Device address via \(plan.backend)."
        return plan
    }
}

public protocol MacHostNetworkMutating: Sendable {
    func apply(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
        plan: MacHostBridgeApplyResult,
    ) throws
}

public final class RecordingMacHostNetworkMutator: MacHostNetworkMutating, @unchecked Sendable {
    public private(set) var steps: [String] = []

    public init() {}

    public func apply(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
        plan: MacHostBridgeApplyResult,
    ) throws {
        steps.append("action=\(request.action.rawValue)")
        steps.append("backend=\(plan.backend)")
        steps.append(contentsOf: plan.changes)
        steps.append(contentsOf: plan.commands)
        _ = probe
    }
}

public protocol MacHostNetworkMarkerStore: Sendable {
    func markerExists(at url: URL) -> Bool
    func writeMarker(_ data: Data, to url: URL) throws
    func readMarker(from url: URL) -> Data?
    func removeMarker(at url: URL) throws
}

public protocol MacHostNetworkCommandRunning: Sendable {
    func runNetworksetup(arguments: [String]) throws -> CommandResult
}

public final class MemoryMacHostNetworkMarkerStore: MacHostNetworkMarkerStore, @unchecked Sendable {
    public private(set) var files: [String: Data] = [:]

    public init() {}

    public func markerExists(at url: URL) -> Bool {
        files[url.path] != nil
    }

    public func writeMarker(_ data: Data, to url: URL) throws {
        files[url.path] = data
    }

    public func readMarker(from url: URL) -> Data? {
        files[url.path]
    }

    public func removeMarker(at url: URL) throws {
        files.removeValue(forKey: url.path)
    }
}

public final class MacHostNetworkFileMutator: MacHostNetworkMutating, @unchecked Sendable {
    private let files: any MacHostNetworkMarkerStore
    private let runner: any MacHostNetworkCommandRunning

    public init(files: any MacHostNetworkMarkerStore, commands: any MacHostNetworkCommandRunning) {
        self.files = files
        self.runner = commands
    }

    public func apply(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
        plan _: MacHostBridgeApplyResult,
    ) throws {
        let service = MacHostBridgeApply.resolvedService(request: request, probe: probe)
        guard !service.isEmpty else {
            throw BarkVisorError.badRequest("Missing hardware-port service name for Device address.")
        }
        if request.action == .revert {
            let marker = probe.marker ?? loadMarker(service: service, dataDir: probe.dataDir)
            try runNetworksetup(MacHostBridgeApply.revertCommands(marker: marker, service: service))
            try? files.removeMarker(at: MacHostBridgeApply.markerURL(service: service, dataDir: probe.dataDir))
            return
        }
        try writeMarkerIfMissing(service: service, request: request, probe: probe)
        try runNetworksetup(MacHostBridgeApply.applyCommands(request: request, service: service))
    }

    private func writeMarkerIfMissing(
        service: String,
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
    ) throws {
        let url = MacHostBridgeApply.markerURL(service: service, dataDir: probe.dataDir)
        if files.markerExists(at: url) { return }
        let snapshot = captureSnapshot(service: service, request: request, probe: probe)
        try files.writeMarker(JSONEncoder().encode(snapshot), to: url)
    }

    private func captureSnapshot(
        service: String,
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
    ) -> MacHostNetworkSnapshot {
        let device = request.nic ?? probe.facts.defaultRouteInterface
        if let result = try? runner.runNetworksetup(arguments: ["-getinfo", service]), result.succeeded {
            let text = result.stdoutString
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return MacHostNetworkSnapshot.fromGetInfo(text, service: service, device: device)
            }
        }
        return probe.marker ?? MacHostNetworkSnapshot(
            service: service,
            device: device,
            addressing: MacHostBridgeAddressing.dhcp.rawValue,
        )
    }

    private func loadMarker(service: String, dataDir: URL) -> MacHostNetworkSnapshot? {
        let url = MacHostBridgeApply.markerURL(service: service, dataDir: dataDir)
        guard let data = files.readMarker(from: url) else { return nil }
        return try? JSONDecoder().decode(MacHostNetworkSnapshot.self, from: data)
    }

    private func runNetworksetup(_ commands: [String]) throws {
        for command in commands {
            let argv = Self.argv(from: command)
            guard argv.count >= 2 else { continue }
            let result = try runner.runNetworksetup(arguments: Array(argv.dropFirst()))
            if !result.succeeded {
                throw BarkVisorError.internalError(
                    "networksetup failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                )
            }
        }
    }

    static func argv(from command: String) -> [String] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("sudo ") ? String(trimmed.dropFirst(5)) : trimmed
        var parts: [String] = []
        var current = ""
        var quoted = false
        for ch in body {
            if ch == "\"" {
                quoted.toggle()
                continue
            }
            if ch == " ", !quoted {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

struct FileManagerMacHostNetworkMarkerStore: MacHostNetworkMarkerStore {
    func markerExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func writeMarker(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try data.write(to: url, options: .atomic)
    }

    func readMarker(from url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    func removeMarker(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

#if os(macOS)
    struct PlatformMacHostNetworkCommandRunner: MacHostNetworkCommandRunning {
        func runNetworksetup(arguments: [String]) throws -> CommandResult {
            try PlatformProcess.run(path: "/usr/sbin/networksetup", arguments: arguments, timeout: 15)
        }
    }

    struct LiveMacHostNetworkMutator: MacHostNetworkMutating {
        private let inner = MacHostNetworkFileMutator(
            files: FileManagerMacHostNetworkMarkerStore(),
            commands: PlatformMacHostNetworkCommandRunner(),
        )

        func apply(
            request: MacHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
            plan: MacHostBridgeApplyResult,
        ) throws {
            try inner.apply(request: request, probe: probe, plan: plan)
        }
    }
#endif
