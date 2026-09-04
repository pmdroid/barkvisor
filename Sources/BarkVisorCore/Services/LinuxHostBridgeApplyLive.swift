import Foundation
#if os(Linux)
    import Glibc
#endif

/// Host-mutating apply. Planner stays in `LinuxHostBridgeApply`; this writes files.
public enum LinuxHostBridgeApplyLive {
    public static func run(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe? = nil,
        mutator: (any LinuxHostBridgeMutating)? = nil,
    ) throws -> LinuxHostBridgeApplyResult {
        try PlatformCapabilities.requireHostMutation()
        let resolved: LinuxHostBridgeApplyProbe
        if let probe {
            resolved = probe
        } else {
            #if os(Linux)
                resolved = LinuxHostBridgeApply.liveProbe(bridge: request.bridge, nic: request.nic)
            #else
                throw BarkVisorError.forbidden("Linux host-bridge apply runs on a Linux Device.")
            #endif
        }
        var plan = LinuxHostBridgeApply.evaluate(request: request, probe: resolved)
        if plan.conflict {
            throw BarkVisorError.conflict(plan.message)
        }
        guard plan.success, !plan.needsConfirm, !plan.refused else {
            return plan
        }
        if request.action == .check || request.action == .dryRun {
            return plan
        }
        if request.action == .delete, !request.confirm {
            return plan
        }
        #if os(Linux)
            let writer: any LinuxHostBridgeMutating = mutator ?? LiveLinuxHostBridgeMutator()
        #else
            guard let writer = mutator else {
                throw BarkVisorError.forbidden("Linux host-bridge apply runs on a Linux Device.")
            }
        #endif
        switch request.action {
        case .apply:
            let addressOnly = LinuxHostBridgeApply.isAddressOnlyApply(
                request: request,
                probe: resolved,
            )
            let createdNow = addressOnly
                ? false
                : LinuxHostBridgeApply.createdBridge(
                    named: request.bridge,
                    existingInterfaces: resolved.existingInterfaces,
                    factsBridges: resolved.facts.bridges,
                )
            try writer.apply(request: request, probe: resolved, plan: plan)
            plan.applied = true
            let appliedOn = addressOnly
                ? LinuxHostBridgeApply.addressApplyDevice(request: request, probe: resolved)
                : request.bridge
            let nic = request.nic ?? LinuxHostBridgeApply.addressApplyDevice(request: request, probe: resolved)
            let target = addressOnly ? nic : request.bridge
            let pending = HostNetworkPendingCommitService.readLinux(bridge: target)
                ?? HostNetworkPendingCommitService.makePending(
                    target: target,
                    createdBridge: createdNow,
                )
            plan.pendingCommit = true
            plan.commitDeadline = pending.commitDeadline
            plan.rollbackSeconds = pending.rollbackSeconds
            plan.createdBridge = createdNow
            plan.message =
                "Applied \(appliedOn) via \(plan.backend). Keep changes within \(pending.rollbackSeconds)s or they auto-revert."
        case .commit:
            try writer.commit(request: request, probe: resolved)
            plan.applied = true
            plan.pendingCommit = false
            plan.message = "Kept host network changes for \(request.bridge)."
        case .revert:
            try writer.apply(request: request, probe: resolved, plan: plan)
            plan.applied = true
            plan.pendingCommit = false
            plan.message = "Reverted BarkVisor \(request.bridge) files. \(request.bridge) was not deleted."
        case .delete:
            try writer.apply(request: request, probe: resolved, plan: plan)
            plan.applied = true
            plan.pendingCommit = false
            plan.message = "Deleted \(request.bridge)."
        case .check, .dryRun:
            break
        }
        return plan
    }
}

public protocol LinuxHostBridgeMutating: Sendable {
    func apply(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
        plan: LinuxHostBridgeApplyResult,
    ) throws

    func commit(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) throws
}

/// Records writes for tests. Never touches the host.
public final class RecordingLinuxHostBridgeMutator: LinuxHostBridgeMutating, @unchecked Sendable {
    public private(set) var steps: [String] = []

    public init() {}

    public func apply(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
        plan: LinuxHostBridgeApplyResult,
    ) throws {
        steps.append("action=\(request.action.rawValue)")
        steps.append("backend=\(probe.backend.rawValue)")
        steps.append(contentsOf: plan.changes)
    }

    public func commit(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) throws {
        steps.append("action=commit")
        steps.append("backend=\(probe.backend.rawValue)")
        steps.append("bridge=\(request.bridge)")
    }
}

#if os(Linux)
    struct LiveLinuxHostBridgeMutator: LinuxHostBridgeMutating {
        func apply(
            request: LinuxHostBridgeApplyRequest,
            probe: LinuxHostBridgeApplyProbe,
            plan _: LinuxHostBridgeApplyResult,
        ) throws {
            if request.action == .revert {
                if LinuxHostBridgeApply.isAddressOnlyApply(request: request, probe: probe) {
                    try revertAddresses(request: request, probe: probe)
                    return
                }
                try withClaim(pendingKey(request: request, probe: probe)) {
                    try revert(request: request, probe: probe)
                }
                return
            }
            if request.action == .delete {
                try withClaim(pendingKey(request: request, probe: probe)) {
                    try deleteOwned(request: request, probe: probe)
                }
                return
            }
            do {
                try HostNetworkPendingCommitService.withApplyGate {
                    try withClaim(pendingKey(request: request, probe: probe)) {
                        try persist(request: request, probe: probe)
                    }
                }
            } catch {
                if case BarkVisorError.conflict = error {
                    throw error
                }
                if LinuxHostBridgeApply.isAddressOnlyApply(request: request, probe: probe) {
                    try? revertAddresses(request: request, probe: probe)
                } else {
                    try? revert(request: request, probe: probe)
                }
                throw error
            }
        }

        func commit(
            request: LinuxHostBridgeApplyRequest,
            probe: LinuxHostBridgeApplyProbe,
        ) throws {
            let target = pendingKey(request: request, probe: probe)
            try withClaim(target) {
                if HostNetworkPendingCommitService.stampExists(target) {
                    HostNetworkPendingCommitService.clearLinux(bridge: target)
                    return
                }
                guard let pending = HostNetworkPendingCommitService.readLinux(bridge: target)
                    ?? HostNetworkPendingCommitService.readLinux(bridge: request.bridge)
                else {
                    throw BarkVisorError.badRequest("No pending host network apply for \(target).")
                }
                if pending.expired {
                    throw BarkVisorError.badRequest(
                        "Pending apply expired. Network may have auto-reverted — run Revert to clean up.",
                    )
                }
                try confirmNetplanKeep(pending: pending, target: target, probe: probe)
                try writeAtomically(LinuxHostBridgeApply.commitStampPath(bridge: target), "")
                try? FileManager.default.removeItem(
                    atPath: HostNetworkPendingCommitService.keepingPath(target),
                )
                stopRollbackTimer(bridge: target)
                HostNetworkPendingCommitService.clearLinux(bridge: target)
            }
        }

        private func persist(request: LinuxHostBridgeApplyRequest, probe: LinuxHostBridgeApplyProbe) throws {
            let target = pendingKey(request: request, probe: probe)
            if let other = HostNetworkPendingCommitService.blockingPending(
                target: target,
                existing: HostNetworkPendingCommitService.listLinuxPending(),
            ) {
                throw BarkVisorError.conflict(
                    "A host network apply is already pending for \(other.target). Keep or Revert it first.",
                )
            }
            let nic = request.nic ?? probe.facts.defaultRouteInterface ?? ""
            guard !nic.isEmpty else {
                throw BarkVisorError.badRequest("No wired uplink for \(request.bridge).")
            }
            guard case let .success(plan) = HostInterfaceAddressApply.resolve(from: request) else {
                throw BarkVisorError.badRequest("Invalid host address plan.")
            }
            if LinuxHostBridgeApply.isAddressOnlyApply(request: request, probe: probe) {
                try persistAddresses(request: request, probe: probe, plan: plan)
                return
            }
            var pendingNetplan: Process?
            switch probe.backend {
            case .netplan:
                try writeAtomically(
                    LinuxHostBridgeApply.netplanPath(bridge: request.bridge),
                    LinuxHostBridgeApply.netplanYAML(
                        bridge: request.bridge,
                        nic: nic,
                        plan: plan,
                    ),
                )
                pendingNetplan = try beginNetplanTry()
            case .networkManager:
                try applyNetworkManager(request: request, nic: nic, plan: plan)
            case .systemdNetworkd:
                try writeNetworkd(request: request, nic: nic, plan: plan)
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/networkctl",
                    arguments: ["reload"],
                    timeout: 30,
                )
            case .ifupdown, .unknown:
                throw BarkVisorError.badRequest(
                    "Refuse \(probe.backend.rawValue). Persist br0 with NetworkManager, netplan, or systemd-networkd.",
                )
            }
            try writeACL(bridge: request.bridge, existing: probe.aclContents)
            // Marker before setuid so Revert can clean up if chmod hits EROFS.
            try LinuxHostBridgeApply.writeOwnerMarker(
                bridge: request.bridge,
                uplink: nic,
                createdBridge: LinuxHostBridgeApply.createdBridgeForApply(request: request, probe: probe),
            )
            let helperModes = try setuidHelpers(probe.helperPaths)
            let pending = HostNetworkPendingCommitService.makePending(
                target: request.bridge,
                createdBridge: LinuxHostBridgeApply.createdBridge(
                    named: request.bridge,
                    existingInterfaces: probe.existingInterfaces,
                    factsBridges: probe.facts.bridges,
                ),
                netplanPid: pendingNetplan.map { Int32($0.processIdentifier) },
                helperModes: helperModes.isEmpty ? nil : helperModes,
            )
            try HostNetworkPendingCommitService.writeLinux(pending)
            try startRollbackTimer(bridge: request.bridge)
        }

        private func persistAddresses(
            request: LinuxHostBridgeApplyRequest,
            probe: LinuxHostBridgeApplyProbe,
            plan: HostInterfaceAddressApplyPlan,
        ) throws {
            let iface = LinuxHostBridgeApply.addressApplyDevice(request: request, probe: probe)
            let nic = request.nic ?? iface
            let desired = plan.dhcpEnabled ? plan.staticCIDRs : plan.aliasCIDRs
            let live = (try? ipv4CIDRs(on: iface)) ?? probe.liveIPv4CIDRs
            var keep = probe.keepIPv4CIDRs
            if keep.isEmpty, plan.dhcpEnabled, let primary = live.first {
                keep = [primary]
            }
            let cidrs = LinuxHostAddressPersist.cidrsNotOnDevice(desired, live: live)
            let removed = LinuxHostAddressPersist.cidrsToRemove(desired: desired, live: live, keep: keep)
            let files = LinuxHostAddressPersist.persistFiles(
                interface: iface,
                cidrs: desired,
                backend: probe.backend,
            )
            let persistRestore: [(String, String?)] = files.map { file in
                if FileManager.default.fileExists(atPath: file.path) {
                    return (file.path, try? String(contentsOfFile: file.path, encoding: .utf8))
                }
                return (file.path, nil)
            }
            for file in files {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: file.path).deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                if desired.isEmpty {
                    try? FileManager.default.removeItem(atPath: file.path)
                } else {
                    try writeAtomically(file.path, file.body)
                }
            }
            var nmConnection = ""
            if probe.backend == .networkManager {
                nmConnection = nmConnectionName(interface: iface)
                try persistNmAddresses(interface: iface, cidrs: cidrs, add: true)
                try persistNmAddresses(interface: iface, cidrs: removed, add: false)
            }
            if probe.backend == .systemdNetworkd || probe.backend == .netplan {
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/networkctl",
                    arguments: ["reload"],
                    timeout: 15,
                )
            }
            for cidr in cidrs {
                let result = try PlatformProcess.run(
                    path: Self.ipPath,
                    arguments: ["addr", "add", cidr, "dev", iface],
                    timeout: 15,
                )
                if !result.succeeded, !LinuxHostAddressPersist.ipAddrAddAlreadyPresent(result.stderrString) {
                    throw BarkVisorError.preconditionFailed(
                        "ip addr add failed for \(cidr) on \(iface): \(result.stderrString)",
                    )
                }
            }
            for cidr in removed {
                _ = try? PlatformProcess.run(
                    path: Self.ipPath,
                    arguments: ["addr", "del", cidr, "dev", iface],
                    timeout: 15,
                )
            }
            let pending = HostNetworkPendingCommitService.makePending(
                target: nic,
                createdBridge: false,
            )
            try HostNetworkPendingCommitService.writeLinux(pending)
            do {
                try startAddressRollbackTimer(
                    device: nic,
                    iface: iface,
                    cidrs: cidrs,
                    persistFiles: files.map(\.path),
                    restoreCIDRs: removed,
                    persistRestore: persistRestore,
                    nmConnection: nmConnection,
                )
            } catch {
                try? revertAddresses(request: request, probe: probe)
                throw error
            }
        }

        private func nmConnectionName(interface: String) -> String {
            let shown = (try? PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["-t", "-f", "GENERAL.CONNECTION", "device", "show", interface],
                timeout: 15,
            ))
            let name = shown?.stdoutString
                .split(separator: ":", maxSplits: 1)
                .last
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if name.isEmpty || name == "--" { return "" }
            return name
        }

        private func persistNmAddresses(interface: String, cidrs: [String], add: Bool) throws {
            let name = nmConnectionName(interface: interface)
            guard !name.isEmpty else { return }
            let flag = add ? "+ipv4.addresses" : "-ipv4.addresses"
            for cidr in cidrs {
                _ = try PlatformProcess.run(
                    path: "/usr/bin/nmcli",
                    arguments: ["connection", "modify", name, flag, cidr],
                    timeout: 15,
                )
            }
            let file = try PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["-g", "connection.filename", "connection", "show", name],
                timeout: 15,
            )
            let src = file.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if src.contains("/run/"), FileManager.default.fileExists(atPath: src) {
                let dest = "/etc/NetworkManager/system-connections/\((src as NSString).lastPathComponent)"
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: dest).deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try? FileManager.default.removeItem(atPath: dest)
                try FileManager.default.copyItem(atPath: src, toPath: dest)
                _ = try? PlatformProcess.run(
                    path: "/bin/chmod",
                    arguments: ["0600", dest],
                    timeout: 5,
                )
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/nmcli",
                    arguments: ["connection", "reload"],
                    timeout: 15,
                )
            }
        }

        private func revertAddresses(
            request: LinuxHostBridgeApplyRequest,
            probe: LinuxHostBridgeApplyProbe,
        ) throws {
            let nic = request.nic ?? LinuxHostBridgeApply.addressApplyDevice(request: request, probe: probe)
            stopRollbackTimer(bridge: nic)
            let helper = "/run/barkvisor/\(nic)-rollback.sh"
            if FileManager.default.isExecutableFile(atPath: helper) {
                _ = try? PlatformProcess.run(path: helper, arguments: [], timeout: 15)
            }
            HostNetworkPendingCommitService.clearLinux(bridge: nic)
        }

        private func startAddressRollbackTimer(
            device: String,
            iface: String,
            cidrs: [String],
            persistFiles: [String] = [],
            restoreCIDRs: [String] = [],
            persistRestore: [(String, String?)] = [],
            nmConnection: String = "",
        ) throws {
            let unit = "barkvisor-\(device)-rollback"
            stopRollbackTimer(bridge: device)
            let stamp = LinuxHostBridgeApply.commitStampPath(bridge: device)
            try FileManager.default.createDirectory(
                atPath: "/run/barkvisor",
                withIntermediateDirectories: true,
            )
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: stamp).deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let helper = "/run/barkvisor/\(device)-rollback.sh"
            try writeAtomically(
                helper,
                LinuxHostBridgeApply.addressRollbackHelperScript(
                    device: device,
                    iface: iface,
                    cidrs: cidrs,
                    persistFiles: persistFiles,
                    restoreCIDRs: restoreCIDRs,
                    persistRestore: persistRestore,
                    nmConnection: nmConnection,
                ),
            )
            _ = try? PlatformProcess.run(path: "/bin/chmod", arguments: ["0755", helper], timeout: 5)
            let armed = try PlatformProcess.run(
                path: "/usr/bin/systemd-run",
                arguments: [
                    "--on-active=\(LinuxHostBridgeApply.rollbackSeconds)s",
                    "--unit=\(unit)",
                    helper,
                ],
                timeout: 15,
            )
            if !armed.succeeded {
                throw BarkVisorError.internalError(
                    "Could not arm \(LinuxHostBridgeApply.rollbackSeconds)s revert timer: \(armed.stderrString)",
                )
            }
            try? FileManager.default.removeItem(atPath: stamp)
        }

        private func deleteOwned(
            request: LinuxHostBridgeApplyRequest,
            probe: LinuxHostBridgeApplyProbe,
        ) throws {
            if request.attachedWorkloadCount > 0 {
                throw BarkVisorError.conflict(
                    "Cannot delete \(request.bridge): \(request.attachedWorkloadCount) Workload(s) still reference it.",
                )
            }
            let members = probe.facts.bridges.first { $0.name == request.bridge }?.enslaved ?? []
            let nic = request.nic ?? members.first ?? probe.facts.defaultRouteInterface ?? ""
            let ports = members.isEmpty && !nic.isEmpty ? [nic] : members
            let cidrs = (try? ipv4CIDRs(on: request.bridge)) ?? []
            try persistDropSystemdBridge(bridge: request.bridge, cidrs: cidrs)
            if probe.backend == .networkManager, !nic.isEmpty {
                unslaveNmPort(nic: nic, cidrs: cidrs)
            }
            for port in ports {
                _ = try? PlatformProcess.run(
                    path: Self.ipPath,
                    arguments: ["link", "set", port, "nomaster"],
                    timeout: 15,
                )
            }
            if !nic.isEmpty {
                for cidr in cidrs {
                    _ = try? PlatformProcess.run(
                        path: Self.ipPath,
                        arguments: ["addr", "add", cidr, "dev", nic],
                        timeout: 15,
                    )
                }
            }
            if probe.backend == .networkManager {
                for port in ports {
                    _ = try? PlatformProcess.run(
                        path: "/usr/bin/nmcli",
                        arguments: [
                            "connection", "delete",
                            LinuxHostBridgeApply.nmSlaveConnectionName(bridge: request.bridge, nic: port),
                        ],
                        timeout: 15,
                    )
                }
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/nmcli",
                    arguments: ["connection", "delete", "barkvisor-\(request.bridge)"],
                    timeout: 15,
                )
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/nmcli",
                    arguments: ["connection", "delete", request.bridge],
                    timeout: 15,
                )
            }
            _ = try? PlatformProcess.run(
                path: Self.ipPath,
                arguments: ["link", "delete", request.bridge, "type", "bridge"],
                timeout: 15,
            )
            try revert(request: request, probe: probe)
            _ = try? PlatformProcess.run(
                path: "/usr/bin/networkctl",
                arguments: ["reload"],
                timeout: 15,
            )
            if probe.backend == .networkManager, !nic.isEmpty {
                persistNmFileIfRuntime(connection: nic)
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/nmcli",
                    arguments: ["connection", "up", nic],
                    timeout: 30,
                )
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/nmcli",
                    arguments: ["device", "reapply", nic],
                    timeout: 15,
                )
            }
            HostNetworkPendingCommitService.clearLinux(bridge: request.bridge)
        }

        private func persistDropSystemdBridge(bridge: String, cidrs: [String]) throws {
            let persist = LinuxHostBridgeApply.systemdBridgePersist(bridge: bridge)
            for path in persist.remove {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: "\(path).d")
            }
            for path in persist.rewrite {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let next = LinuxHostBridgeApply.rewritePortNetworkDroppingBridge(
                    text,
                    bridge: bridge,
                    cidrs: cidrs,
                )
                try next.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }

        private func unslaveNmPort(nic: String, cidrs: [String]) {
            _ = try? PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: [
                    "connection", "modify", nic,
                    "connection.slave-type", "",
                    "connection.master", "",
                    "connection.port-type", "",
                    "connection.controller", "",
                ],
                timeout: 15,
            )
            _ = try? PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: [
                    "connection", "modify", nic,
                    "ipv4.method", "auto",
                    "connection.autoconnect", "yes",
                ],
                timeout: 15,
            )
            guard !cidrs.isEmpty else { return }
            _ = try? PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: [
                    "connection", "modify", nic,
                    "ipv4.addresses", cidrs.joined(separator: ","),
                ],
                timeout: 15,
            )
            persistNmFileIfRuntime(connection: nic)
        }

        private func persistNmFileIfRuntime(connection: String) {
            let listed = try? PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["-t", "-f", "NAME,FILENAME", "connection", "show"],
                timeout: 15,
            )
            guard let listed else { return }
            var src = ""
            for raw in listed.stdoutString.split(whereSeparator: \.isNewline) {
                let line = String(raw)
                guard let sep = line.firstIndex(of: ":") else { continue }
                let name = String(line[..<sep])
                if name == connection {
                    src = String(line[line.index(after: sep)...])
                    break
                }
            }
            guard src.contains("/run/"), FileManager.default.fileExists(atPath: src) else { return }
            let dest = "/etc/NetworkManager/system-connections/\((src as NSString).lastPathComponent)"
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dest).deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try? FileManager.default.removeItem(atPath: dest)
            try? FileManager.default.copyItem(atPath: src, toPath: dest)
            _ = try? PlatformProcess.run(path: "/bin/chmod", arguments: ["0600", dest], timeout: 5)
            _ = try? PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["connection", "reload"],
                timeout: 15,
            )
        }

        private func ipv4CIDRs(on device: String) throws -> [String] {
            let result = try PlatformProcess.run(
                path: Self.ipPath,
                arguments: ["-4", "-o", "addr", "show", "dev", device],
                timeout: 10,
            )
            guard result.succeeded else { return [] }
            var cidrs: [String] = []
            for raw in result.stdoutString.split(whereSeparator: \.isNewline) {
                let parts = String(raw).split(whereSeparator: \.isWhitespace).map(String.init)
                guard let inet = parts.firstIndex(of: "inet"), inet + 1 < parts.count else { continue }
                let cidr = parts[inet + 1]
                if cidr.hasPrefix("127.") { continue }
                cidrs.append(cidr)
            }
            return cidrs
        }

        private static var ipPath: String {
            ["/usr/sbin/ip", "/sbin/ip", "/usr/bin/ip"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            } ?? "/sbin/ip"
        }

        private func revert(request: LinuxHostBridgeApplyRequest, probe: LinuxHostBridgeApplyProbe) throws {
            let pending = HostNetworkPendingCommitService.readLinux(bridge: request.bridge)
            if let pid = pending?.netplanPid, pid > 0 {
                _ = kill(pid_t(pid), SIGTERM)
            }
            stopRollbackTimer(bridge: request.bridge)
            var nic = request.nic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if nic.isEmpty {
                nic = probe.facts.defaultRouteInterface ?? ""
            }
            if nic.isEmpty {
                nic = LinuxHostBridgeApply.readOwnerMarker(bridge: request.bridge)?.uplink ?? ""
            }
            switch probe.backend {
            case .netplan:
                try? FileManager.default.removeItem(atPath: LinuxHostBridgeApply.netplanPath(bridge: request.bridge))
                _ = try? PlatformProcess.run(
                    path: "/usr/sbin/netplan",
                    arguments: ["apply"],
                    timeout: 30,
                )
            case .networkManager:
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/nmcli",
                    arguments: ["connection", "delete", "barkvisor-\(request.bridge)"],
                    timeout: 30,
                )
                if !nic.isEmpty {
                    _ = try? PlatformProcess.run(
                        path: "/usr/bin/nmcli",
                        arguments: [
                            "connection", "delete",
                            LinuxHostBridgeApply.nmSlaveConnectionName(bridge: request.bridge, nic: nic),
                        ],
                        timeout: 30,
                    )
                    _ = try? PlatformProcess.run(
                        path: "/usr/bin/nmcli",
                        arguments: ["device", "reapply", nic],
                        timeout: 30,
                    )
                }
            case .systemdNetworkd:
                try? FileManager.default.removeItem(atPath: LinuxHostBridgeApply.networkdNetdevPath(bridge: request.bridge))
                try? FileManager.default.removeItem(atPath: LinuxHostBridgeApply.networkdNetworkPath(bridge: request.bridge))
                if !nic.isEmpty {
                    try? FileManager.default.removeItem(atPath: LinuxHostBridgeApply.networkdPortPath(nic: nic))
                }
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/networkctl",
                    arguments: ["reload"],
                    timeout: 30,
                )
                if !nic.isEmpty {
                    _ = try? PlatformProcess.run(
                        path: "/usr/bin/networkctl",
                        arguments: ["reapply", nic],
                        timeout: 30,
                    )
                }
            case .ifupdown, .unknown:
                throw BarkVisorError.badRequest(
                    "Refuse \(probe.backend.rawValue). Cannot revert a manager we do not own.",
                )
            }
            if let existing = probe.aclContents {
                try writeAtomically(
                    HostBridgeFactsService.defaultACLPath,
                    LinuxHostBridgeApply.stripMarkedACL(existing: existing, bridge: request.bridge),
                )
            }
            if let helperModes = pending?.helperModes {
                for (path, mode) in helperModes.sorted(by: { $0.key < $1.key })
                where FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: mode)],
                        ofItemAtPath: path,
                    )
                }
            }
            try? FileManager.default.removeItem(
                at: LinuxHostBridgeApply.ownerMarkerURL(bridge: request.bridge),
            )
            try? FileManager.default.removeItem(
                atPath: LinuxHostBridgeApply.commitStampPath(bridge: request.bridge),
            )
            HostNetworkPendingCommitService.clearLinux(bridge: request.bridge)
        }

        private func writeACL(bridge: String, existing: String?) throws {
            let dir = (HostBridgeFactsService.defaultACLPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
            )
            try writeAtomically(
                HostBridgeFactsService.defaultACLPath,
                LinuxHostBridgeApply.mergeACL(existing: existing, bridge: bridge),
            )
        }

        private func setuidHelpers(_ paths: [String]) throws -> [String: Int] {
            var modes: [String: Int] = [:]
            for path in paths where FileManager.default.fileExists(atPath: path) {
                var attrs = try FileManager.default.attributesOfItem(atPath: path)
                let current = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                modes[path] = Int(current)
                attrs[.posixPermissions] = NSNumber(value: current | 0o4000 | 0o111)
                try FileManager.default.setAttributes(attrs, ofItemAtPath: path)
            }
            return modes
        }

        private func writeNetworkd(
            request: LinuxHostBridgeApplyRequest,
            nic: String,
            plan: HostInterfaceAddressApplyPlan,
        ) throws {
            let netdev = """
            # managed-by: barkvisor
            [NetDev]
            Name=\(request.bridge)
            Kind=bridge
            """
            var network = """
            # managed-by: barkvisor
            [Match]
            Name=\(request.bridge)

            [Network]
            """
            if plan.dhcpEnabled {
                network += "\nDHCP=yes\n"
            }
            for cidr in plan.staticCIDRs {
                network += "Address=\(cidr)\n"
            }
            if let gateway = plan.gateway, !plan.dhcpEnabled {
                network += "Gateway=\(gateway)\n"
            }
            for dns in plan.dns {
                network += "DNS=\(dns)\n"
            }
            network += "\n[Bridge]\n"
            try writeAtomically(LinuxHostBridgeApply.networkdNetdevPath(bridge: request.bridge), netdev)
            try writeAtomically(LinuxHostBridgeApply.networkdNetworkPath(bridge: request.bridge), network)
            let portNetwork = """
            # managed-by: barkvisor
            [Match]
            Name=\(nic)

            [Network]
            Bridge=\(request.bridge)
            """
            try writeAtomically(
                LinuxHostBridgeApply.networkdPortPath(nic: nic),
                portNetwork,
            )
            try LinuxHostAddressPersist.migrateAliasUnitOntoPort(interface: nic)
        }

        private func applyNetworkManager(
            request: LinuxHostBridgeApplyRequest,
            nic: String,
            plan: HostInterfaceAddressApplyPlan,
        ) throws {
            let name = "barkvisor-\(request.bridge)"
            _ = try? PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["connection", "delete", name],
                timeout: 15,
            )
            var add = [
                "connection", "add", "type", "bridge", "ifname", request.bridge,
                "con-name", name,
            ]
            if plan.dhcpEnabled {
                add += ["ipv4.method", "auto"]
            } else {
                add += ["ipv4.method", "manual"]
            }
            if !plan.staticCIDRs.isEmpty {
                add += ["ipv4.addresses", plan.staticCIDRs.joined(separator: ",")]
            }
            if let gateway = plan.gateway, !plan.dhcpEnabled {
                add += ["ipv4.gateway", gateway]
            }
            if !plan.dns.isEmpty {
                add += ["ipv4.dns", plan.dns.joined(separator: ",")]
            }
            let added = try PlatformProcess.run(path: "/usr/bin/nmcli", arguments: add, timeout: 30)
            if !added.succeeded {
                throw BarkVisorError.internalError(
                    "nmcli failed: \(added.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                )
            }
            let slave = LinuxHostBridgeApply.nmSlaveConnectionName(bridge: request.bridge, nic: nic)
            _ = try? PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["connection", "delete", slave],
                timeout: 15,
            )
            let addedSlave = try PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: [
                    "connection", "add", "type", "bridge-slave", "ifname", nic,
                    "master", request.bridge, "con-name", slave,
                ],
                timeout: 30,
            )
            if !addedSlave.succeeded {
                throw BarkVisorError.internalError(
                    "nmcli failed: \(addedSlave.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                )
            }
            _ = try PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["connection", "modify", name, "connection.autoconnect-ports", "1"],
                timeout: 15,
            )
            let upBridge = try PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["connection", "up", name],
                timeout: 30,
            )
            if !upBridge.succeeded {
                throw BarkVisorError.internalError(
                    "nmcli connection up \(name) failed: \(upBridge.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                )
            }
            let upSlave = try PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["connection", "up", slave],
                timeout: 30,
            )
            if !upSlave.succeeded {
                throw BarkVisorError.internalError(
                    "nmcli connection up \(slave) failed: \(upSlave.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                )
            }
        }

        /// Start `netplan try` without waiting. Persist needs SIGUSR1 (netplan-try(8));
        /// waiting for exit always hits the timeout and reverts.
        private func beginNetplanTry() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/netplan")
            process.arguments = ["try", "--timeout", String(LinuxHostBridgeApply.rollbackSeconds)]
            process.standardInput = FileHandle.nullDevice
            let err = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = err
            try process.run()
            let readyDeadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < readyDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if !process.isRunning, process.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    ?? ""
                throw BarkVisorError.internalError(
                    "netplan try failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))",
                )
            }
            return process
        }

        private func pendingKey(
            request: LinuxHostBridgeApplyRequest,
            probe: LinuxHostBridgeApplyProbe,
        ) -> String {
            if LinuxHostBridgeApply.isAddressOnlyApply(request: request, probe: probe) {
                return request.nic ?? LinuxHostBridgeApply.addressApplyDevice(request: request, probe: probe)
            }
            return request.bridge
        }

        private func withClaim(_ target: String, _ body: () throws -> Void) throws {
            guard HostNetworkPendingCommitService.claimRevert(target) else {
                throw BarkVisorError.conflict(
                    "Host network keep or revert already in progress for \(target).",
                )
            }
            defer { HostNetworkPendingCommitService.releaseRevert(target) }
            try body()
        }

        private func confirmNetplanKeep(
            pending: HostNetworkPendingCommit,
            target: String,
            probe: LinuxHostBridgeApplyProbe,
        ) throws {
            guard probe.backend == .netplan, let pid = pending.netplanPid, pid > 0 else { return }
            guard LinuxHostBridgeApply.isNetplanProcess(pid: pid) else {
                throw BarkVisorError.internalError("netplan try did not keep the config.")
            }
            try Data().write(
                to: URL(fileURLWithPath: HostNetworkPendingCommitService.keepingPath(target)),
                options: .atomic,
            )
            if kill(pid_t(pid), SIGUSR1) != 0 {
                try? FileManager.default.removeItem(
                    atPath: HostNetworkPendingCommitService.keepingPath(target),
                )
                throw BarkVisorError.internalError("Could not SIGUSR1 netplan try to keep the config.")
            }
            let deadline = Date().addingTimeInterval(30)
            var status: Int32 = 0
            var waited: pid_t = 0
            while Date() < deadline {
                waited = waitpid(pid_t(pid), &status, WNOHANG)
                if waited != 0 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if waited > 0, status == 0 { return }
            try? FileManager.default.removeItem(
                atPath: HostNetworkPendingCommitService.keepingPath(target),
            )
            throw BarkVisorError.internalError("netplan try did not keep the config.")
        }

        /// Host timer. Do not wait for the SPA after the uplink moves.
        /// Apply must write the commit stamp or this unit reverts.
        private func startRollbackTimer(bridge: String) throws {
            let unit = "barkvisor-\(bridge)-rollback"
            stopRollbackTimer(bridge: bridge)
            let stamp = LinuxHostBridgeApply.commitStampPath(bridge: bridge)
            try FileManager.default.createDirectory(
                atPath: "/run/barkvisor",
                withIntermediateDirectories: true,
            )
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: stamp).deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let helper = "/run/barkvisor/\(bridge)-rollback.sh"
            try writeAtomically(
                helper,
                LinuxHostBridgeApply.rollbackHelperScript(
                    bridge: bridge,
                    dataDir: Config.dataDir.path,
                ),
            )
            _ = try? PlatformProcess.run(path: "/bin/chmod", arguments: ["0755", helper], timeout: 5)
            let armed = try PlatformProcess.run(
                path: "/usr/bin/systemd-run",
                arguments: [
                    "--on-active=\(LinuxHostBridgeApply.rollbackSeconds)s",
                    "--unit=\(unit)",
                    helper,
                ],
                timeout: 15,
            )
            if !armed.succeeded {
                throw BarkVisorError.internalError(
                    "Could not arm \(LinuxHostBridgeApply.rollbackSeconds)s revert timer: \(armed.stderrString)",
                )
            }
            try? FileManager.default.removeItem(atPath: stamp)
        }

        private func stopRollbackTimer(bridge: String) {
            let unit = "barkvisor-\(bridge)-rollback"
            _ = try? PlatformProcess.run(
                path: "/usr/bin/systemctl",
                arguments: ["stop", "\(unit).timer"],
                timeout: 10,
            )
            _ = try? PlatformProcess.run(
                path: "/usr/bin/systemctl",
                arguments: ["stop", "\(unit).service"],
                timeout: 10,
            )
        }

        private func writeAtomically(_ path: String, _ contents: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }
#endif
