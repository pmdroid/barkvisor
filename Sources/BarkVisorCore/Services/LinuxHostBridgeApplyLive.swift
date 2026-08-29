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
                resolved = LinuxHostBridgeApply.liveProbe()
            #else
                throw BarkVisorError.forbidden("Linux host-bridge apply runs on a Linux Device.")
            #endif
        }
        var plan = LinuxHostBridgeApply.evaluate(request: request, probe: resolved)
        guard plan.success, !plan.needsConfirm, !plan.refused else {
            return plan
        }
        if request.action == .check || request.action == .dryRun {
            return plan
        }
        #if os(Linux)
            let writer: any LinuxHostBridgeMutating = mutator ?? LiveLinuxHostBridgeMutator()
        #else
            guard let writer = mutator else {
                throw BarkVisorError.forbidden("Linux host-bridge apply runs on a Linux Device.")
            }
        #endif
        try writer.apply(request: request, probe: resolved, plan: plan)
        plan.applied = true
        plan.message = request.action == .revert
            ? "Reverted BarkVisor \(request.bridge) files. \(request.bridge) was not deleted."
            : "Applied \(request.bridge) via \(plan.backend)."
        return plan
    }
}

public protocol LinuxHostBridgeMutating: Sendable {
    func apply(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
        plan: LinuxHostBridgeApplyResult,
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
}

#if os(Linux)
    struct LiveLinuxHostBridgeMutator: LinuxHostBridgeMutating {
        func apply(
            request: LinuxHostBridgeApplyRequest,
            probe: LinuxHostBridgeApplyProbe,
            plan _: LinuxHostBridgeApplyResult,
        ) throws {
            if request.action == .revert {
                try revert(request: request, probe: probe)
                return
            }
            try persist(request: request, probe: probe)
        }

        private func persist(request: LinuxHostBridgeApplyRequest, probe: LinuxHostBridgeApplyProbe) throws {
            let nic = request.nic ?? probe.facts.defaultRouteInterface ?? ""
            guard !nic.isEmpty else {
                throw BarkVisorError.badRequest("No wired uplink for \(request.bridge).")
            }
            var pendingNetplan: Process?
            switch probe.backend {
            case .netplan:
                try writeAtomically(
                    LinuxHostBridgeApply.netplanPath,
                    LinuxHostBridgeApply.netplanYAML(
                        bridge: request.bridge,
                        nic: nic,
                        addressing: request.addressing,
                        address: request.address,
                        gateway: request.gateway,
                        dns: request.dns,
                    ),
                )
                pendingNetplan = try beginNetplanTry()
            case .networkManager:
                try applyNetworkManager(request: request, nic: nic)
                try startRollbackTimer(bridge: request.bridge)
            case .systemdNetworkd:
                try writeNetworkd(request: request, nic: nic)
                try startRollbackTimer(bridge: request.bridge)
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
            try writeOwnerMarker(bridge: request.bridge, createdBridge: probe.facts.bridges.isEmpty)
            try setuidHelpers(probe.helperPaths)
            try commitApply(bridge: request.bridge, netplan: pendingNetplan)
        }

        private func revert(request: LinuxHostBridgeApplyRequest, probe: LinuxHostBridgeApplyProbe) throws {
            switch probe.backend {
            case .netplan:
                try? FileManager.default.removeItem(atPath: LinuxHostBridgeApply.netplanPath)
                try commitNetplanTry(beginNetplanTry())
            case .networkManager:
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/nmcli",
                    arguments: ["connection", "delete", "barkvisor-\(request.bridge)"],
                    timeout: 30,
                )
            case .systemdNetworkd:
                try? FileManager.default.removeItem(atPath: LinuxHostBridgeApply.networkdNetdevPath)
                try? FileManager.default.removeItem(atPath: LinuxHostBridgeApply.networkdNetworkPath)
                _ = try? PlatformProcess.run(
                    path: "/usr/bin/networkctl",
                    arguments: ["reload"],
                    timeout: 30,
                )
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
            try? FileManager.default.removeItem(
                at: LinuxHostBridgeApply.ownerMarkerURL(bridge: request.bridge),
            )
            try? FileManager.default.removeItem(
                atPath: LinuxHostBridgeApply.commitStampPath(bridge: request.bridge),
            )
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

        private func setuidHelpers(_ paths: [String]) throws {
            for path in paths where FileManager.default.fileExists(atPath: path) {
                var attrs = try FileManager.default.attributesOfItem(atPath: path)
                let current = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                attrs[.posixPermissions] = NSNumber(value: current | 0o4000 | 0o111)
                try FileManager.default.setAttributes(attrs, ofItemAtPath: path)
            }
        }

        private func writeOwnerMarker(bridge: String, createdBridge: Bool) throws {
            let url = LinuxHostBridgeApply.ownerMarkerURL(bridge: bridge)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let payload = ["bridge": bridge, "createdBridge": createdBridge] as [String: Any]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
        }

        private func writeNetworkd(request: LinuxHostBridgeApplyRequest, nic: String) throws {
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
            switch request.addressing {
            case .dhcp:
                network += "\nDHCP=yes\n"
            case .staticIP:
                if let address = request.address {
                    network += "\nAddress=\(address)\n"
                }
                if let gateway = request.gateway {
                    network += "Gateway=\(gateway)\n"
                }
                for dns in request.dns {
                    network += "DNS=\(dns)\n"
                }
            }
            network += "\n[Bridge]\n"
            _ = nic
            try writeAtomically(LinuxHostBridgeApply.networkdNetdevPath, netdev)
            try writeAtomically(LinuxHostBridgeApply.networkdNetworkPath, network)
            let portNetwork = """
            # managed-by: barkvisor
            [Match]
            Name=\(nic)

            [Network]
            Bridge=\(request.bridge)
            """
            try writeAtomically(
                "/etc/systemd/network/90-barkvisor-\(nic).network",
                portNetwork,
            )
        }

        private func applyNetworkManager(request: LinuxHostBridgeApplyRequest, nic: String) throws {
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
            switch request.addressing {
            case .dhcp:
                add += ["ipv4.method", "auto"]
            case .staticIP:
                add += ["ipv4.method", "manual"]
                if let address = request.address {
                    add += ["ipv4.addresses", address]
                }
                if let gateway = request.gateway {
                    add += ["ipv4.gateway", gateway]
                }
                if !request.dns.isEmpty {
                    add += ["ipv4.dns", request.dns.joined(separator: ",")]
                }
            }
            let added = try PlatformProcess.run(path: "/usr/bin/nmcli", arguments: add, timeout: 30)
            if !added.succeeded {
                throw BarkVisorError.internalError(
                    "nmcli failed: \(added.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                )
            }
            _ = try PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: [
                    "connection", "add", "type", "bridge-slave", "ifname", nic,
                    "master", request.bridge, "con-name", "\(name)-\(nic)",
                ],
                timeout: 30,
            )
            _ = try PlatformProcess.run(
                path: "/usr/bin/nmcli",
                arguments: ["connection", "up", name],
                timeout: 30,
            )
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

        private func commitNetplanTry(_ process: Process) throws {
            if process.isRunning {
                if kill(process.processIdentifier, SIGUSR1) != 0 {
                    throw BarkVisorError.internalError("Could not SIGUSR1 netplan try to keep the config.")
                }
            }
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                throw BarkVisorError.timeout("netplan try did not exit after SIGUSR1.")
            }
            if process.terminationStatus != 0 {
                throw BarkVisorError.internalError("netplan try failed after commit.")
            }
        }

        private func commitApply(bridge: String, netplan: Process?) throws {
            try writeAtomically(LinuxHostBridgeApply.commitStampPath(bridge: bridge), "")
            if let netplan {
                try commitNetplanTry(netplan)
            }
        }

        /// Host timer. Do not wait for the SPA after the uplink moves.
        /// Apply must write the commit stamp or this unit always reverts.
        private func startRollbackTimer(bridge: String) throws {
            let unit = "barkvisor-\(bridge)-rollback"
            _ = try? PlatformProcess.run(
                path: "/usr/bin/systemctl",
                arguments: ["stop", "\(unit).timer"],
                timeout: 10,
            )
            let stamp = LinuxHostBridgeApply.commitStampPath(bridge: bridge)
            try FileManager.default.createDirectory(
                atPath: "/run/barkvisor",
                withIntermediateDirectories: true,
            )
            try? FileManager.default.removeItem(atPath: stamp)
            let helper = "/run/barkvisor/\(bridge)-rollback.sh"
            try writeAtomically(helper, LinuxHostBridgeApply.rollbackHelperScript(bridge: bridge))
            _ = try? PlatformProcess.run(path: "/bin/chmod", arguments: ["0755", helper], timeout: 5)
            _ = try? PlatformProcess.run(
                path: "/usr/bin/systemd-run",
                arguments: [
                    "--on-active=\(LinuxHostBridgeApply.rollbackSeconds)s",
                    "--unit=\(unit)",
                    helper,
                ],
                timeout: 15,
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
