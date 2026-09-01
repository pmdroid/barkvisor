import Foundation

#if os(macOS)

    /// macOS bridged host setup: start `socket_vmnet` and set Device IPv4 on the wired uplink.
    public struct MacHostBridgeApplyProbe: Sendable, Equatable {
        public var facts: HostBridgeFacts
        public var device: String
        public var serviceName: String?
        public var socketProbe: SocketVmnetApplyProbe
        public var createdBridge: Bool

        public init(
            facts: HostBridgeFacts,
            device: String,
            serviceName: String?,
            socketProbe: SocketVmnetApplyProbe,
            createdBridge: Bool = false,
        ) {
            self.facts = facts
            self.device = device
            self.serviceName = serviceName
            self.socketProbe = socketProbe
            self.createdBridge = createdBridge
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
            let created = device.map { LinuxHostBridgeApply.createdBridgeForUplink($0) } ?? false
            return MacHostBridgeApplyProbe(
                facts: facts,
                device: device ?? "",
                serviceName: service,
                socketProbe: socketProbe,
                createdBridge: created,
            )
        }

        public static func evaluate(
            request: LinuxHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
        ) -> LinuxHostBridgeApplyResult {
            switch request.action {
            case .revert:
                return revertPlan(request: request, probe: probe)
            case .delete:
                return deletePlan(request: request, probe: probe)
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
            let changes = [
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

            let changes = HostInterfaceAddressApply.plannedDiffs(
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
            )

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

            return LinuxHostBridgeApplyResult(
                success: true,
                applied: false,
                needsConfirm: false,
                backend: "networksetup",
                changes: changes.map(\.description),
                warnings: warnings,
                commands: commands,
                message: dryRun
                    ? "Dry run: Device address apply plan."
                    : "Apply Device addresses on \(service) (\(device)).",
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
            let device = resolvedDevice(nic: request.nic, facts: probe.facts)
                ?? markerUplink(request: request)
                ?? probe.device
            if device.isEmpty {
                return refuse("No interface to revert.")
            }
            var changes: [String] = []
            if MacHostNetworkApply.readMarker(device: device) != nil {
                changes.append("Restore saved networksetup profile for \(device)")
            } else {
                changes.append("Set \(device) back to DHCP (no saved profile)")
            }
            changes.append("Strip BarkVisor markers for \(device)")
            return LinuxHostBridgeApplyResult(
                success: true,
                applied: false,
                needsConfirm: false,
                backend: "networksetup",
                changes: changes,
                warnings: [],
                commands: [
                    "sudo networksetup -setdhcp \"\(probe.serviceName ?? "Ethernet")\"",
                    "# strip host-bridge marker; never ip link del",
                ],
                message: "Revert restores the saved Device address. socket_vmnet stays.",
            )
        }

        private static func deletePlan(
            request: LinuxHostBridgeApplyRequest,
            probe: MacHostBridgeApplyProbe,
        ) -> LinuxHostBridgeApplyResult {
            let created = probe.createdBridge
                || LinuxHostBridgeApply.readOwnerMarker(bridge: request.bridge)?.createdBridge == true
            if !created {
                return refuse("Refuse delete of foreign \(request.bridge). Revert strips BarkVisor files only.")
            }
            if request.attachedWorkloadCount > 0 {
                let n = request.attachedWorkloadCount
                return LinuxHostBridgeApplyResult(
                    success: false,
                    applied: false,
                    needsConfirm: false,
                    backend: "networksetup",
                    changes: [],
                    warnings: [],
                    commands: [],
                    message: "Cannot delete \(request.bridge): \(n) Workload\(n == 1 ? "" : "s") still reference it.",
                    refused: true,
                    conflict: true,
                )
            }
            let device = resolvedDevice(nic: request.nic, facts: probe.facts)
                ?? markerUplink(request: request)
                ?? probe.device
            if device.isEmpty {
                return refuse("No interface to delete.")
            }
            var changes: [String] = []
            if MacHostNetworkApply.readMarker(device: device) != nil {
                changes.append("Restore saved networksetup profile for \(device)")
            } else {
                changes.append("Set \(device) back to DHCP (no saved profile)")
            }
            changes.append("Stop BarkVisor-managed socket_vmnet for \(device)")
            changes.append("Strip BarkVisor markers")
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
                message:
                "Ready to delete owned socket_vmnet. Keep changes within \(HostNetworkPendingCommitService.rollbackSeconds)s or they auto-revert.",
            )
        }

        private static func markerUplink(request: LinuxHostBridgeApplyRequest) -> String? {
            LinuxHostBridgeApply.readOwnerMarker(bridge: request.bridge)?.uplink
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
            if plan.conflict {
                throw BarkVisorError.conflict(plan.message)
            }
            guard plan.success, !plan.needsConfirm else { return plan }
            if request.action == .check || request.action == .dryRun {
                return plan
            }

            switch request.action {
            case .apply:
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
                    "Applied Device addresses on \(service) (\(resolved.device)). Keep changes within \(pending.rollbackSeconds)s or they auto-revert."
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
                let uplink = LinuxHostBridgeApply.readOwnerMarker(bridge: request.bridge)?.uplink
                try? FileManager.default.removeItem(
                    at: LinuxHostBridgeApply.ownerMarkerURL(bridge: request.bridge),
                )
                if let uplink {
                    try? FileManager.default.removeItem(
                        at: LinuxHostBridgeApply.ownerMarkerURL(bridge: uplink),
                    )
                }
                plan.applied = true
                plan.pendingCommit = false
                plan.message = "Reverted BarkVisor host network files. socket_vmnet was not stopped."
            case .delete:
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
                MacHostNetworkApply.removeMarker(device: resolved.device)
                try? FileManager.default.removeItem(
                    at: LinuxHostBridgeApply.ownerMarkerURL(bridge: request.bridge),
                )
                let pending = HostNetworkPendingCommitService.makePending(target: resolved.device)
                try HostNetworkPendingCommitService.writeMac(pending)
                plan.applied = true
                plan.pendingCommit = true
                plan.commitDeadline = pending.commitDeadline
                plan.rollbackSeconds = pending.rollbackSeconds
                plan.message =
                    "Deleted owned socket_vmnet on \(resolved.device). Keep changes within \(pending.rollbackSeconds)s or they auto-revert."
            case .check, .dryRun:
                break
            }
            return plan
        }
    }

#endif
