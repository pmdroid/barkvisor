import Foundation

#if os(macOS)

    /// macOS bridged host setup: start `socket_vmnet` and set Device IPv4 on the wired uplink.
    public struct MacHostBridgeApplyProbe: Sendable, Equatable {
        public var facts: HostBridgeFacts
        public var device: String
        public var serviceName: String?
        public var socketProbe: SocketVmnetApplyProbe

        public init(
            facts: HostBridgeFacts,
            device: String,
            serviceName: String?,
            socketProbe: SocketVmnetApplyProbe,
        ) {
            self.facts = facts
            self.device = device
            self.serviceName = serviceName
            self.socketProbe = socketProbe
        }
    }

    public enum MacHostBridgeApply {
        public static func liveProbe(
            nic: String?,
            facts: HostBridgeFacts = HostBridgeFactsService.probe(),
        ) throws -> MacHostBridgeApplyProbe {
            let device = resolvedDevice(nic: nic, facts: facts)
            let service = try device.flatMap { try MacHostNetworkApply.serviceName(forDevice: $0) }
            let socketProbe = SocketVmnetApply.liveProbe(interface: device)
            return MacHostBridgeApplyProbe(
                facts: facts,
                device: device ?? "",
                serviceName: service,
                socketProbe: socketProbe,
            )
        }

        public static func evaluate(
            request: LinuxHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
        ) -> LinuxHostBridgeApplyResult {
            switch request.action {
            case .revert:
                return revertPlan(request: request, probe: probe)
            case .check:
                return check(request: request, probe: probe)
            case .dryRun:
                return applyPlan(request: request, probe: probe, dryRun: true)
            case .commit:
                return commitPlan(request: request, probe: probe)
            case .apply:
                return applyPlan(request: request, probe: probe, dryRun: false)
            }
        }

        private static func check(probe: MacHostBridgeApplyProbe) -> LinuxHostBridgeApplyResult {
            var changes = [
                probe.facts.ready
                    ? "Bridged networking is ready on this Device."
                    : "Bridged networking is not ready yet.",
            ]
            return LinuxHostBridgeApplyResult(
                success: probe.facts.ready,
                applied: false,
                needsConfirm: false,
                backend: "networksetup",
                changes: changes,
                warnings: [],
                commands: [],
                message: probe.facts.ready
                    ? "Bridged networking is ready on this Device."
                    : "Bridged networking is not ready yet.",
            )
        }

        private static func check(
            request: LinuxHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
        ) -> LinuxHostBridgeApplyResult {
            var result = check(probe: probe)
            if case let .success(plan) = HostInterfaceAddressApply.resolve(from: request) {
                let label = probe.serviceName.map { "\($0) (\(probe.device))" } ?? probe.device
                result.changes += HostInterfaceAddressApply.plannedDiffs(plan: plan, interfaceLabel: label)
            }
            return result
        }

        private static func applyPlan(
            request: LinuxHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
            dryRun: Bool,
        ) -> LinuxHostBridgeApplyResult {
            let device = probe.device
            if device.isEmpty {
                return refuse("No wired uplink. Connect Ethernet or pass interface.")
            }
            if MacHostNetworkApply.isLoopbackDevice(device) {
                return refuse("Refuse loopback '\(device)'.")
            }
            guard let service = probe.serviceName else {
                return refuse("No networksetup service for '\(device)'.")
            }
            if MacHostNetworkApply.isWiFiPort(service) {
                return refuse("Refuse Wi-Fi '\(service)'. Bridge a wired NIC.")
            }
            let planResult = HostInterfaceAddressApply.resolve(from: request)
            guard case let .success(plan) = planResult else {
                if case let .failure(error) = planResult {
                    return refuse(error.message)
                }
                return refuse("Invalid address plan.")
            }

            var warnings: [String] = []
            if probe.facts.onlyUplink {
                warnings.append(
                    "This Device has a single uplink. Changing its address can drop SSH and the SPA.",
                )
            }
            warnings.append(
                "After Apply, click Keep changes within \(HostNetworkPendingCommitService.rollbackSeconds)s or Revert to undo.",
            )

            let socketPlan = SocketVmnetApply.evaluate(
                request: SocketVmnetApplyRequest(
                    action: probe.socketProbe.ownedServiceLoaded || probe.socketProbe.brewServiceLoaded
                        ? .start : .setup,
                    interface: device,
                ),
                probe: probe.socketProbe,
            )
            var changes = socketPlan.changes.map {
                LinuxHostBridgeChange(description: $0, command: "")
            }
            changes += HostInterfaceAddressApply.plannedDiffs(
                plan: plan,
                interfaceLabel: "\(service) (\(device))",
            ).map {
                LinuxHostBridgeChange(description: $0, command: "")
            }
            changes.append(
                LinuxHostBridgeChange(
                    description: "Map \(request.bridge) → \(device) in host-bridge-\(request.bridge).json",
                    command: "",
                ),
            )
            let commands = MacHostNetworkApply.equivalentCommands(
                service: service,
                device: device,
                plan: plan,
            ) + socketPlan.commands

            if !request.confirm, probe.facts.onlyUplink {
                return LinuxHostBridgeApplyResult(
                    success: false,
                    applied: false,
                    needsConfirm: true,
                    backend: "networksetup",
                    changes: changes.map(\.description),
                    warnings: warnings,
                    commands: commands,
                    message: "Confirm required: this NIC is the only uplink.",
                )
            }

            if socketPlan.refused {
                return LinuxHostBridgeApplyResult(
                    success: false,
                    applied: false,
                    needsConfirm: false,
                    backend: socketPlan.backend,
                    changes: changes.map(\.description),
                    warnings: warnings + socketPlan.warnings,
                    commands: commands,
                    message: socketPlan.message,
                )
            }

            return LinuxHostBridgeApplyResult(
                success: true,
                applied: false,
                needsConfirm: false,
                backend: "networksetup",
                changes: changes.map(\.description),
                warnings: warnings,
                commands: commands,
                message: dryRun
                    ? "Dry run: bridged host apply plan."
                    : "Apply bridged host networking (socket_vmnet + Device address).",
            )
        }

        private static func commitPlan(
            request: LinuxHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
        ) -> LinuxHostBridgeApplyResult {
            let device = probe.device
            guard !device.isEmpty else {
                return refuse("No interface to commit.")
            }
            guard let pending = HostNetworkPendingCommitService.readMac(device: device) else {
                return refuse("No pending host network apply for \(device).")
            }
            if pending.expired {
                return refuse(
                    "Pending apply expired. Run Revert to restore the saved network profile.",
                )
            }
            return LinuxHostBridgeApplyResult(
                success: true,
                applied: false,
                backend: "networksetup",
                changes: ["Keep host network changes for \(device)"],
                warnings: [],
                commands: [],
                message: "Ready to keep host network changes for \(device).",
            )
        }

        private static func revertPlan(
            request: LinuxHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
        ) -> LinuxHostBridgeApplyResult {
            let device = probe.device
            if device.isEmpty {
                return refuse("No interface to revert.")
            }
            var changes: [String] = []
            if MacHostNetworkApply.readMarker(device: device) != nil {
                changes.append("Restore saved networksetup profile for \(device)")
            } else {
                changes.append("Set \(device) back to DHCP (no saved profile)")
            }
            changes.append("Stop BarkVisor-managed socket_vmnet when loaded")
            return LinuxHostBridgeApplyResult(
                success: true,
                applied: false,
                needsConfirm: false,
                backend: "networksetup",
                changes: changes,
                warnings: [],
                commands: [
                    "sudo networksetup -setdhcp \"\(probe.serviceName ?? "Ethernet")\"",
                    "launchctl bootout system/com.barkvisor.socket-vmnet.\(device)",
                ],
                message: "Revert BarkVisor host network changes.",
            )
        }

        private static func refuse(_ message: String) -> LinuxHostBridgeApplyResult {
            LinuxHostBridgeApplyResult(
                success: false,
                applied: false,
                needsConfirm: false,
                backend: "networksetup",
                changes: [],
                warnings: [],
                commands: [],
                message: message,
            )
        }

        private static func resolvedDevice(nic: String?, facts: HostBridgeFacts) -> String? {
            if let nic, !nic.isEmpty {
                return SocketVmnetDiscovery.resolveUplink(forBridge: nic)
            }
            if let route = facts.defaultRouteInterface, !route.isEmpty { return route }
            return facts.bridges.first.flatMap { snap in
                snap.enslaved.first ?? snap.name
            }
        }
    }

    public enum MacHostBridgeApplyLive {
        public static func run(
            request: LinuxHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe? = nil,
        ) throws -> LinuxHostBridgeApplyResult {
            try PlatformCapabilities.requireManagedBridgeDaemon()
            let resolved = try probe ?? MacHostBridgeApply.liveProbe(nic: request.nic)
            var plan = MacHostBridgeApply.evaluate(request: request, probe: resolved)
            guard plan.success, !plan.needsConfirm else { return plan }
            if request.action == .check || request.action == .dryRun {
                return plan
            }

            switch request.action {
            case .apply:
                let socketAction: SocketVmnetApplyAction =
                    if resolved.socketProbe.ownedServiceLoaded || resolved.socketProbe.brewServiceLoaded {
                        .start
                    } else {
                        .setup
                    }
                _ = try SocketVmnetApplyLive.run(
                    request: SocketVmnetApplyRequest(action: socketAction, interface: resolved.device),
                    probe: resolved.socketProbe,
                )
                guard let service = resolved.serviceName else {
                    throw BarkVisorError.preconditionFailed("No networksetup service for \(resolved.device).")
                }
                try MacHostNetworkApply.apply(
                    device: resolved.device,
                    service: service,
                    plan: {
                        guard case let .success(plan) = HostInterfaceAddressApply.resolve(from: request) else {
                            throw BarkVisorError.badRequest("Invalid host address plan.")
                        }
                        return plan
                    }(),
                )
                let created = LinuxHostBridgeApply.readOwnerMarker(bridge: request.bridge)?.createdBridge ?? true
                try LinuxHostBridgeApply.writeOwnerMarker(
                    bridge: request.bridge,
                    uplink: resolved.device,
                    createdBridge: created,
                )
                let pending = HostNetworkPendingCommitService.makePending(target: resolved.device)
                try HostNetworkPendingCommitService.writeMac(pending)
                plan.applied = true
                plan.pendingCommit = true
                plan.commitDeadline = pending.commitDeadline
                plan.rollbackSeconds = pending.rollbackSeconds
                plan.message =
                    "Applied bridged host networking on \(service) (\(resolved.device)). Keep changes within \(pending.rollbackSeconds)s or they auto-revert."
            case .commit:
                guard let pending = HostNetworkPendingCommitService.readMac(device: resolved.device) else {
                    throw BarkVisorError.badRequest("No pending host network apply for \(resolved.device).")
                }
                if pending.expired {
                    throw BarkVisorError.badRequest(
                        "Pending apply expired. Run Revert to restore the saved network profile.",
                    )
                }
                HostNetworkPendingCommitService.clearMac(device: resolved.device)
                plan.applied = true
                plan.pendingCommit = false
                plan.message = "Kept host network changes for \(resolved.device)."
            case .revert:
                HostNetworkPendingCommitService.clearMac(device: resolved.device)
                if try MacHostNetworkApply.revert(device: resolved.device) {
                    plan.changes.insert("Restored saved networksetup profile.", at: 0)
                } else if let service = resolved.serviceName {
                    _ = try PlatformProcess.run(
                        path: MacHostNetworkApply.networksetupPath,
                        arguments: ["-setdhcp", service],
                    )
                    plan.changes.insert("Set \(service) to DHCP.", at: 0)
                }
                _ = try? SocketVmnetApplyLive.run(
                    request: SocketVmnetApplyRequest(action: .stop, interface: resolved.device),
                    probe: resolved.socketProbe,
                )
                plan.applied = true
                plan.pendingCommit = false
                plan.message = "Reverted BarkVisor host network changes."
            case .check, .dryRun:
                break
            }
            return plan
        }
    }

#endif
