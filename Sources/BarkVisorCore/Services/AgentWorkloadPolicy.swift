import Foundation

/// Agent-class Workload rules (PAS-268). House is unconstrained here.
public enum AgentWorkloadPolicy {
    public static func validate(
        workloadClass: WorkloadClass,
        usbCount: Int,
        sharedPathCount: Int,
        portForwardCount: Int,
        networkMode: NetworkMode,
    ) throws {
        guard workloadClass == .agent else { return }
        if usbCount > 0 {
            throw BarkVisorError.forbidden("Agent Workloads cannot attach USB")
        }
        if sharedPathCount > 0 {
            throw BarkVisorError.forbidden("Agent Workloads cannot share host folders")
        }
        if portForwardCount > 0 {
            throw BarkVisorError.forbidden("Agent Workloads cannot publish host ports")
        }
        if networkMode == .bridged {
            throw BarkVisorError.forbidden("Agent Workloads cannot join the house LAN")
        }
    }

    public static func validate(spec: WorkloadSpec, network: Network?) throws {
        let klass = try WorkloadClass.parse(spec.spec.workloadClass)
        let mode: NetworkMode = if let network {
            try NetworkCapability.effectiveMode(of: network)
        } else if let raw = spec.spec.networks.first?.mode, !raw.isEmpty {
            try NetworkCapability.parse(raw)
        } else {
            .nat
        }
        let usbCount = spec.spec.usb.count
        let sharedCount = spec.spec.sharedPaths?.count ?? 0
        let forwards = spec.spec.networks.first?.portForwards.count ?? 0
        try validate(
            workloadClass: klass,
            usbCount: usbCount,
            sharedPathCount: sharedCount,
            portForwardCount: forwards,
            networkMode: mode,
        )
        if klass == .agent, spec.spec.networks.count > 1 {
            throw BarkVisorError.forbidden("Agent Workloads allow a single network")
        }
    }

    public static func assertUSBAllowed(_ rawClass: String?) throws {
        let klass = try WorkloadClass.parse(rawClass)
        guard klass == .agent else { return }
        throw BarkVisorError.forbidden("Agent Workloads cannot attach USB")
    }
}
