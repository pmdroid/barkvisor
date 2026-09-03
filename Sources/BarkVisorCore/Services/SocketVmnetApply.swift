import Foundation

/// Start, stop, or verify `socket_vmnet` from the root Device daemon (no XPC).
///
/// Planner is pure (inject `SocketVmnetApplyProbe`). Live start is macOS-only.
/// Never `brew install` as root. Never enslaves a Linux-style `br0`.
public enum SocketVmnetApplyAction: String, Sendable, Codable, Equatable {
    case setup
    case start
    case stop
    case check
}

public enum SocketVmnetBackend: String, Sendable, Codable, Equatable {
    case ownedLaunchd = "owned-launchd"
    case homebrewService = "homebrew-service"
    case none
}

/// Injected host view. Pass `HostBridgeFacts` — do not invent a second facts model.
public struct SocketVmnetApplyProbe: Sendable, Equatable {
    public var facts: HostBridgeFacts
    public var interface: String
    public var binaryPath: String?
    public var ownedPlistPath: String
    public var ownedPlistExists: Bool
    public var ownedServiceLoaded: Bool
    public var brewPath: String?
    public var brewPlistPath: String?
    public var brewFormulaInstalled: Bool
    public var brewServiceLoaded: Bool
    public var sockets: [String]
    public var canWriteLaunchDaemons: Bool

    public init(
        facts: HostBridgeFacts,
        interface: String,
        binaryPath: String? = nil,
        ownedPlistPath: String = SocketVmnetLaunchd.plistURL(interface: "en0").path,
        ownedPlistExists: Bool = false,
        ownedServiceLoaded: Bool = false,
        brewPath: String? = nil,
        brewPlistPath: String? = nil,
        brewFormulaInstalled: Bool = false,
        brewServiceLoaded: Bool = false,
        sockets: [String] = [],
        canWriteLaunchDaemons: Bool = true,
    ) {
        self.facts = facts
        self.interface = interface
        self.binaryPath = binaryPath
        self.ownedPlistPath = ownedPlistPath
        self.ownedPlistExists = ownedPlistExists
        self.ownedServiceLoaded = ownedServiceLoaded
        self.brewPath = brewPath
        self.brewPlistPath = brewPlistPath
        self.brewFormulaInstalled = brewFormulaInstalled
        self.brewServiceLoaded = brewServiceLoaded
        self.sockets = sockets
        self.canWriteLaunchDaemons = canWriteLaunchDaemons
    }
}

public struct SocketVmnetApplyRequest: Sendable, Equatable {
    public var action: SocketVmnetApplyAction
    public var interface: String?

    public init(action: SocketVmnetApplyAction, interface: String? = nil) {
        self.action = action
        self.interface = interface
    }
}

public struct SocketVmnetApplyResult: Sendable, Equatable, Codable {
    public var success: Bool
    public var applied: Bool
    public var needsConfirm: Bool
    public var backend: String
    public var changes: [String]
    public var warnings: [String]
    public var commands: [String]
    public var message: String
    public var refused: Bool

    public init(
        success: Bool,
        applied: Bool = false,
        needsConfirm: Bool = false,
        backend: String,
        changes: [String] = [],
        warnings: [String] = [],
        commands: [String] = [],
        message: String,
        refused: Bool = false,
    ) {
        self.success = success
        self.applied = applied
        self.needsConfirm = needsConfirm
        self.backend = backend
        self.changes = changes
        self.warnings = warnings
        self.commands = commands
        self.message = message
        self.refused = refused
    }
}

public enum SocketVmnetApply {
    public static func evaluate(
        request: SocketVmnetApplyRequest,
        probe: SocketVmnetApplyProbe,
    ) -> SocketVmnetApplyResult {
        switch request.action {
        case .check:
            return check(probe: probe)
        case .stop:
            return stopPlan(probe: probe)
        case .setup, .start:
            return startPlan(request: request, probe: probe)
        }
    }

    /// Live host probe. Uses `HostBridgeFactsService` — no second facts model.
    public static func liveProbe(
        interface: String? = nil,
        facts: HostBridgeFacts = HostBridgeFactsService.probe(),
    ) -> SocketVmnetApplyProbe {
        let iface = resolvedInterface(interface, facts: facts)
        let ownedPlist = SocketVmnetLaunchd.plistURL(interface: iface).path
        let sockets = SocketVmnetDiscovery.candidates(bridgeInterface: iface)
        let existing = sockets.filter { FileManager.default.fileExists(atPath: $0) }
        let binary = SocketVmnetLaunchd.firstExisting(SocketVmnetLaunchd.binaryCandidates)
        let brewPlist = SocketVmnetLaunchd.firstExisting(SocketVmnetLaunchd.homebrewPlistCandidates)
        let brew = SocketVmnetLaunchd.firstExisting(SocketVmnetLaunchd.brewBinaryCandidates)
        #if os(macOS)
            let ownedLoaded = SocketVmnetLaunchd.serviceLoaded(SocketVmnetLaunchd.label(interface: iface))
            let brewLoaded = SocketVmnetLaunchd.serviceLoaded(SocketVmnetLaunchd.homebrewServiceLabel)
        #else
            let ownedLoaded = false
            let brewLoaded = false
        #endif
        return SocketVmnetApplyProbe(
            facts: facts,
            interface: iface,
            binaryPath: binary,
            ownedPlistPath: ownedPlist,
            ownedPlistExists: FileManager.default.fileExists(atPath: ownedPlist),
            ownedServiceLoaded: ownedLoaded,
            brewPath: brew,
            brewPlistPath: brewPlist,
            brewFormulaInstalled: binary != nil || brewPlist != nil,
            brewServiceLoaded: brewLoaded,
            sockets: existing,
            canWriteLaunchDaemons: FileManager.default.isWritableFile(
                atPath: SocketVmnetLaunchd.launchDaemonsDir,
            ),
        )
    }

    public static func resolvedInterface(_ requested: String?, facts: HostBridgeFacts) -> String {
        if let name = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let name = facts.defaultRouteInterface, !name.isEmpty {
            return name
        }
        if let name = facts.bridges.first?.name, !name.isEmpty {
            return name
        }
        return SocketVmnetDiscovery.sharedUplinkInterface() ?? SocketVmnetDiscovery.sharedUplinkCandidates[0]
    }

    public static func pickBackend(probe: SocketVmnetApplyProbe) -> SocketVmnetBackend {
        if probe.canWriteLaunchDaemons {
            return .ownedLaunchd
        }
        if probe.ownedPlistExists || probe.binaryPath != nil {
            return .ownedLaunchd
        }
        if probe.brewFormulaInstalled || probe.brewPlistPath != nil || probe.brewPath != nil {
            return .homebrewService
        }
        return .none
    }

    private static func check(probe: SocketVmnetApplyProbe) -> SocketVmnetApplyResult {
        let backend = runningBackend(probe: probe)
        let socketPresent = !probe.sockets.isEmpty || probe.facts.ready
        var changes = socketLines(probe: probe)
        changes.append(contentsOf: serviceLines(probe: probe))
        let serviceRunning = probe.ownedServiceLoaded || probe.brewServiceLoaded
        let message = if socketPresent, serviceRunning {
            "socket present; service running (\(backend.rawValue))"
        } else if socketPresent {
            "socket present; service not loaded"
        } else if serviceRunning {
            "service running; socket missing"
        } else {
            "socket missing; service not loaded"
        }
        return SocketVmnetApplyResult(
            success: true,
            backend: backend.rawValue,
            changes: changes,
            commands: [checkCommand()],
            message: message,
        )
    }

    private static func startPlan(
        request: SocketVmnetApplyRequest,
        probe: SocketVmnetApplyProbe,
    ) -> SocketVmnetApplyResult {
        let backend = pickBackend(probe: probe)
        guard backend != .none else {
            return SocketVmnetApplyResult(
                success: false,
                backend: SocketVmnetBackend.none.rawValue,
                warnings: [SocketVmnetDiscovery.installHint],
                commands: ["brew install socket_vmnet"],
                message: SocketVmnetDiscovery.installHint,
                refused: true,
            )
        }
        var changes: [String] = []
        var commands: [String] = []
        switch backend {
        case .ownedLaunchd:
            changes.append("Write \(probe.ownedPlistPath)")
            changes.append("launchctl bootstrap \(probe.ownedPlistPath)")
            commands.append("sudo launchctl bootstrap system \(probe.ownedPlistPath)")
        case .homebrewService:
            changes.append("Start already-installed Homebrew socket_vmnet (formula already present)")
            if probe.brewPlistPath != nil {
                commands.append(
                    "launchctl bootstrap system \(probe.brewPlistPath ?? SocketVmnetLaunchd.homebrewPlistCandidates[0])",
                )
            } else {
                commands.append("brew services start socket_vmnet")
            }
        case .none:
            break
        }
        return SocketVmnetApplyResult(
            success: true,
            backend: backend.rawValue,
            changes: changes,
            commands: commands,
            message: request.action == .setup
                ? "Setup socket_vmnet via \(backend.rawValue)"
                : "Start socket_vmnet via \(backend.rawValue)",
        )
    }

    private static func stopPlan(probe: SocketVmnetApplyProbe) -> SocketVmnetApplyResult {
        let backend = runningBackend(probe: probe)
        var changes: [String] = []
        var commands: [String] = []
        if probe.ownedPlistExists || probe.ownedServiceLoaded {
            let label = SocketVmnetLaunchd.label(interface: probe.interface)
            changes.append("launchctl bootout \(label)")
            commands.append("sudo launchctl bootout system/\(label)")
        }
        if probe.brewServiceLoaded || probe.brewPlistPath != nil {
            changes.append("launchctl bootout \(SocketVmnetLaunchd.homebrewServiceLabel)")
            commands.append("sudo launchctl bootout system/\(SocketVmnetLaunchd.homebrewServiceLabel)")
        }
        if changes.isEmpty {
            changes.append("No socket_vmnet service loaded")
        }
        return SocketVmnetApplyResult(
            success: true,
            backend: backend.rawValue,
            changes: changes,
            commands: commands.isEmpty
                ? ["POST /api/system/interfaces (interface: \(probe.interface), action: revert, confirm: true)"]
                : commands,
            message: "Stop socket_vmnet (\(backend.rawValue))",
        )
    }

    private static func runningBackend(probe: SocketVmnetApplyProbe) -> SocketVmnetBackend {
        if probe.ownedServiceLoaded { return .ownedLaunchd }
        if probe.brewServiceLoaded { return .homebrewService }
        return pickBackend(probe: probe)
    }

    private static func socketLines(probe: SocketVmnetApplyProbe) -> [String] {
        let candidates = SocketVmnetDiscovery.candidates(bridgeInterface: probe.interface)
        let present = Set(probe.sockets)
        let lines = candidates.map { path in
            "socket=\(path) present=\(present.contains(path) ? "yes" : "no")"
        }
        if lines.isEmpty {
            return ["socket=missing present=no"]
        }
        return lines
    }

    private static func serviceLines(probe: SocketVmnetApplyProbe) -> [String] {
        [
            "service=\(SocketVmnetLaunchd.label(interface: probe.interface)) loaded=\(probe.ownedServiceLoaded ? "yes" : "no")",
            "service=\(SocketVmnetLaunchd.homebrewServiceLabel) loaded=\(probe.brewServiceLoaded ? "yes" : "no")",
        ]
    }

    private static func checkCommand() -> String {
        "GET /api/system/host-bridge-readiness"
    }
}
