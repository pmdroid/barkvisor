import Foundation

/// Host-mutating start/stop. Planner stays in `SocketVmnetApply`.
public enum SocketVmnetApplyLive {
    public static func run(
        request: SocketVmnetApplyRequest,
        probe: SocketVmnetApplyProbe? = nil,
        mutator: (any SocketVmnetMutating)? = nil,
    ) throws -> SocketVmnetApplyResult {
        let resolved: SocketVmnetApplyProbe
        if let probe {
            resolved = probe
        } else {
            try PlatformCapabilities.requireManagedBridgeDaemon()
            #if os(macOS)
                resolved = SocketVmnetApply.liveProbe(interface: request.interface)
            #else
                throw BarkVisorError.forbidden("socket_vmnet start/stop runs on a macOS Device.")
            #endif
        }
        var plan = SocketVmnetApply.evaluate(request: request, probe: resolved)
        guard plan.success, !plan.refused else {
            return plan
        }
        if request.action == .check {
            return plan
        }
        #if os(macOS)
            let writer: any SocketVmnetMutating = mutator ?? LiveSocketVmnetMutator()
        #else
            guard let writer = mutator else {
                throw BarkVisorError.forbidden("socket_vmnet start/stop runs on a macOS Device.")
            }
        #endif
        try writer.apply(request: request, probe: resolved, plan: plan)
        plan.applied = true
        switch request.action {
        case .stop:
            plan.message = "Stopped socket_vmnet. NAT Workloads still work."
        case .setup:
            plan.message = "Set up socket_vmnet via \(plan.backend)."
        case .start:
            plan.message = "Started socket_vmnet via \(plan.backend)."
        case .check:
            break
        }
        return plan
    }
}

public protocol SocketVmnetMutating: Sendable {
    func apply(
        request: SocketVmnetApplyRequest,
        probe: SocketVmnetApplyProbe,
        plan: SocketVmnetApplyResult,
    ) throws
}

/// Records writes for tests. Never touches the host.
public final class RecordingSocketVmnetMutator: SocketVmnetMutating, @unchecked Sendable {
    public private(set) var steps: [String] = []

    public init() {}

    public func apply(
        request: SocketVmnetApplyRequest,
        probe: SocketVmnetApplyProbe,
        plan: SocketVmnetApplyResult,
    ) throws {
        steps.append("action=\(request.action.rawValue)")
        steps.append("backend=\(plan.backend)")
        steps.append("interface=\(probe.interface)")
        steps.append(contentsOf: plan.changes)
    }
}

#if os(macOS)
    struct LiveSocketVmnetMutator: SocketVmnetMutating {
        func apply(
            request: SocketVmnetApplyRequest,
            probe: SocketVmnetApplyProbe,
            plan: SocketVmnetApplyResult,
        ) throws {
            try validateBridgeName(probe.interface)
            switch request.action {
            case .check:
                return
            case .stop:
                try SocketVmnetLaunchd.stop(interface: probe.interface)
                try? SocketVmnetLaunchd.stopHomebrewService()
            case .setup, .start:
                if plan.backend == SocketVmnetBackend.ownedLaunchd.rawValue {
                    try SocketVmnetLaunchd.start(interface: probe.interface)
                } else if plan.backend == SocketVmnetBackend.homebrewService.rawValue {
                    try SocketVmnetLaunchd.startHomebrewService()
                } else {
                    throw BarkVisorError.preconditionFailed(SocketVmnetDiscovery.installHint)
                }
            }
        }
    }
#endif
