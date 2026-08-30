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

#if os(macOS)
    struct LiveMacHostNetworkMutator: MacHostNetworkMutating {
        func apply(
            request: MacHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
            plan _: MacHostBridgeApplyResult,
        ) throws {
            let service = MacHostBridgeApply.resolvedService(request: request, probe: probe)
            guard !service.isEmpty else {
                throw BarkVisorError.badRequest("Missing hardware-port service name for Device address.")
            }
            if request.action == .revert {
                try runNetworksetup(MacHostBridgeApply.revertCommands(marker: probe.marker, service: service))
                try? FileManager.default.removeItem(
                    at: MacHostBridgeApply.markerURL(service: service, dataDir: probe.dataDir),
                )
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
            if FileManager.default.fileExists(atPath: url.path) { return }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let snapshot = probe.marker ?? MacHostNetworkSnapshot(
                service: service,
                device: request.nic ?? probe.facts.defaultRouteInterface,
                addressing: MacHostBridgeAddressing.dhcp.rawValue,
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        }

        private func runNetworksetup(_ commands: [String]) throws {
            for command in commands {
                let argv = argv(from: command)
                guard argv.count >= 2 else { continue }
                let result = try PlatformProcess.run(
                    path: "/usr/sbin/networksetup",
                    arguments: Array(argv.dropFirst()),
                    timeout: 15,
                )
                if !result.succeeded {
                    throw BarkVisorError.internalError(
                        "networksetup failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                    )
                }
            }
        }

        private func argv(from command: String) -> [String] {
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
#endif
