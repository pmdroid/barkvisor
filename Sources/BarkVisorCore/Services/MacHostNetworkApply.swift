import Foundation

#if os(macOS)

    /// Host IPv4 on the wired uplink via `networksetup` (Ventura+ compatible).
    /// Device address only — not guest/workload addressing.
    public enum MacHostNetworkApply {
        public static let markerDirName = "host-network"
        public static let networksetupPath = "/usr/sbin/networksetup"

        public struct HardwarePort: Sendable, Equatable {
            public var name: String
            public var device: String

            public init(name: String, device: String) {
                self.name = name
                self.device = device
            }
        }

        public struct Snapshot: Codable, Sendable, Equatable {
            public var device: String
            public var service: String
            public var infoText: String
            public var dnsServers: [String]
            /// `ifconfig alias` CIDRs applied after the snapshot was taken (removed on revert).
            public var appliedAliasCIDRs: [String]

            public init(
                device: String,
                service: String,
                infoText: String,
                dnsServers: [String],
                appliedAliasCIDRs: [String] = [],
            ) {
                self.device = device
                self.service = service
                self.infoText = infoText
                self.dnsServers = dnsServers
                self.appliedAliasCIDRs = appliedAliasCIDRs
            }

            enum CodingKeys: String, CodingKey {
                case device, service, infoText, dnsServers, appliedAliasCIDRs
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                device = try container.decode(String.self, forKey: .device)
                service = try container.decode(String.self, forKey: .service)
                infoText = try container.decode(String.self, forKey: .infoText)
                dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
                appliedAliasCIDRs = try container.decodeIfPresent([String].self, forKey: .appliedAliasCIDRs) ?? []
            }
        }

        public static func listHardwarePorts(
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 15)
            },
        ) throws -> [HardwarePort] {
            let result = try run(networksetupPath, ["-listallhardwareports"])
            guard result.succeeded else {
                throw BarkVisorError.preconditionFailed(
                    "networksetup failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                )
            }
            var ports: [HardwarePort] = []
            var currentName: String?
            for raw in result.stdoutString.split(whereSeparator: \.isNewline) {
                let line = String(raw)
                if line.hasPrefix("Hardware Port: ") {
                    currentName = String(line.dropFirst("Hardware Port: ".count))
                } else if line.hasPrefix("Device: "), let name = currentName {
                    let device = String(line.dropFirst("Device: ".count))
                    if !device.isEmpty {
                        ports.append(HardwarePort(name: name, device: device))
                    }
                    currentName = nil
                }
            }
            return ports
        }

        public static func serviceName(
            forDevice device: String,
            ports: [HardwarePort]? = nil,
        ) throws -> String? {
            let rows = try ports ?? listHardwarePorts()
            return rows.first(where: { $0.device == device })?.name
        }

        public static func isWiFiPort(_ name: String) -> Bool {
            let lower = name.lowercased()
            return lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("airport")
        }

        public static func isLoopbackDevice(_ device: String) -> Bool {
            device == "lo0" || device == "lo"
        }

        public static func captureSnapshot(
            device: String,
            service: String,
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 15)
            },
        ) throws -> Snapshot {
            let info = try run(networksetupPath, ["-getinfo", service])
            let dns = try run(networksetupPath, ["-getdnsservers", service])
            let dnsServers = dns.succeeded
                ? parseDNSServers(dns.stdoutString)
                : []
            return Snapshot(
                device: device,
                service: service,
                infoText: info.stdoutString,
                dnsServers: dnsServers,
            )
        }

        public static func parseDNSServers(_ text: String) -> [String] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains("There aren't any") {
                return []
            }
            return trimmed.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        }

        public static func markerURL(device: String, dataDir: URL = Config.dataDir) -> URL {
            dataDir
                .appendingPathComponent(markerDirName, isDirectory: true)
                .appendingPathComponent("\(device).json")
        }

        public static func readMarker(device: String) -> Snapshot? {
            let url = markerURL(device: device)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }

        public static func writeMarker(_ snapshot: Snapshot) throws {
            let url = markerURL(device: snapshot.device)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        }

        public static func removeMarker(device: String) {
            try? FileManager.default.removeItem(at: markerURL(device: device))
        }

        public static func parseStaticAddress(_ raw: String) throws -> (ip: String, mask: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("/") {
                let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2, let prefix = Int(parts[1]), (1 ... 32).contains(prefix) else {
                    throw BarkVisorError.badRequest("address must look like 192.168.1.10/24")
                }
                try validateIPv4(parts[0], label: "address")
                return (parts[0], subnetMask(prefixLength: prefix))
            }
            try validateIPv4(trimmed, label: "address")
            return (trimmed, "255.255.255.0")
        }

        public static func subnetMask(prefixLength: Int) -> String {
            let mask = prefixLength == 0 ? 0 : (0xFFFF_FFFF as UInt32) << (32 - prefixLength)
            return [
                (mask >> 24) & 0xFF,
                (mask >> 16) & 0xFF,
                (mask >> 8) & 0xFF,
                mask & 0xFF,
            ].map(String.init).joined(separator: ".")
        }

        private static func validateIPv4(_ value: String, label: String) throws {
            let parts = value.split(separator: ".")
            guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0 ... 255).contains($0) } == true }) else {
                throw BarkVisorError.badRequest("\(label) must be a valid IPv4 address")
            }
        }

        public static func apply(
            device: String,
            service: String,
            addressing: LinuxHostBridgeAddressing,
            address: String?,
            gateway: String?,
            dns: [String],
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 30)
            },
        ) throws {
            guard case let .success(plan) = HostInterfaceAddressApply.resolveLegacy(
                addressing: addressing,
                address: address,
                gateway: gateway,
                dns: dns,
            ) else {
                throw BarkVisorError.badRequest("Invalid host address plan.")
            }
            try apply(
                device: device,
                service: service,
                plan: plan,
                run: run,
            )
        }

        public static func apply(
            device: String,
            service: String,
            plan: HostInterfaceAddressApplyPlan,
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 30)
            },
        ) throws {
            if readMarker(device: device) == nil {
                let before = try captureSnapshot(device: device, service: service, run: run)
                try writeMarker(before)
            }
            if plan.dhcpEnabled {
                let result = try run(networksetupPath, ["-setdhcp", service])
                guard result.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setdhcp failed: \(result.stderrString)",
                    )
                }
            } else if let primary = plan.primaryStaticCIDR {
                let parsed = try parseStaticAddress(primary)
                guard let gateway = plan.gateway, !gateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BarkVisorError.badRequest("Static host address needs gateway")
                }
                try validateIPv4(gateway, label: "gateway")
                let result = try run(networksetupPath, [
                    "-setmanual", service, parsed.ip, parsed.mask, gateway,
                ])
                guard result.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setmanual failed: \(result.stderrString)",
                    )
                }
            }
            let aliasTargets = plan.dhcpEnabled ? plan.staticCIDRs : plan.aliasCIDRs
            let plannedAliasIPs = try Set(aliasTargets.map { try parseStaticAddress($0).ip })
            let primaryIP: String?
            if plan.dhcpEnabled {
                let info = try run(networksetupPath, ["-getinfo", service])
                primaryIP = info.succeeded ? parseInfoValue(info.stdoutString, key: "IP address") : nil
            } else if let primary = plan.primaryStaticCIDR {
                primaryIP = try parseStaticAddress(primary).ip
            } else {
                primaryIP = nil
            }
            try removeStaleAliases(
                device: device,
                primaryIP: primaryIP,
                plannedAliasIPs: plannedAliasIPs,
                run: run,
            )
            for cidr in aliasTargets {
                let parsed = try parseStaticAddress(cidr)
                let aliasResult = try run(
                    "/sbin/ifconfig",
                    [device, "alias", parsed.ip, "netmask", parsed.mask],
                )
                guard aliasResult.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "ifconfig alias failed for \(cidr): \(aliasResult.stderrString)",
                    )
                }
            }
            if !plan.dns.isEmpty {
                let dnsResult = try run(networksetupPath, ["-setdnsservers", service] + plan.dns)
                guard dnsResult.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setdnsservers failed: \(dnsResult.stderrString)",
                    )
                }
            }
            if !aliasTargets.isEmpty, var marker = readMarker(device: device) {
                marker.appliedAliasCIDRs = aliasTargets
                try writeMarker(marker)
            }
        }

        public static func revert(
            device: String,
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 30)
            },
        ) throws -> Bool {
            guard let marker = readMarker(device: device) else {
                return false
            }
            for cidr in marker.appliedAliasCIDRs {
                let parsed = try parseStaticAddress(cidr)
                let aliasResult = try run("/sbin/ifconfig", [device, "-alias", parsed.ip])
                guard aliasResult.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "ifconfig -alias failed for \(cidr): \(aliasResult.stderrString)",
                    )
                }
            }
            let lower = marker.infoText.lowercased()
            if lower.contains("dhcp configuration") {
                let result = try run(networksetupPath, ["-setdhcp", marker.service])
                guard result.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setdhcp revert failed: \(result.stderrString)",
                    )
                }
            } else if let ip = parseInfoValue(marker.infoText, key: "IP address"),
                      let mask = parseInfoValue(marker.infoText, key: "Subnet mask"),
                      let router = parseInfoValue(marker.infoText, key: "Router") {
                let result = try run(networksetupPath, [
                    "-setmanual", marker.service, ip, mask, router,
                ])
                guard result.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setmanual revert failed: \(result.stderrString)",
                    )
                }
            } else {
                let result = try run(networksetupPath, ["-setdhcp", marker.service])
                guard result.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setdhcp revert failed: \(result.stderrString)",
                    )
                }
            }
            if marker.dnsServers.isEmpty {
                _ = try? run(networksetupPath, ["-setdnsservers", marker.service, "Empty"])
            } else {
                _ = try? run(networksetupPath, ["-setdnsservers", marker.service] + marker.dnsServers)
            }
            removeMarker(device: device)
            return true
        }

        static func listIPv4Addresses(
            device: String,
            run: (String, [String]) throws -> CommandResult,
        ) throws -> [String] {
            let result = try run("/sbin/ifconfig", [device])
            guard result.succeeded else { return [] }
            var ips: [String] = []
            for raw in result.stdoutString.split(whereSeparator: \.isNewline) {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("inet ") else { continue }
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 2, parts[1].contains(".") else { continue }
                ips.append(parts[1])
            }
            return ips
        }

        static func removeStaleAliases(
            device: String,
            primaryIP: String?,
            plannedAliasIPs: Set<String>,
            run: (String, [String]) throws -> CommandResult,
        ) throws {
            let liveIPs = try listIPv4Addresses(device: device, run: run)
            for ip in liveIPs {
                if ip == primaryIP { continue }
                if plannedAliasIPs.contains(ip) { continue }
                let aliasResult = try run("/sbin/ifconfig", [device, "-alias", ip])
                guard aliasResult.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "ifconfig -alias failed for \(ip): \(aliasResult.stderrString)",
                    )
                }
            }
        }

        static func parseInfoValue(_ text: String, key: String) -> String? {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = String(raw)
                guard line.hasPrefix("\(key):") else { continue }
                let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if value.isEmpty || value.lowercased() == "none" { return nil }
                return value
            }
            return nil
        }

        public static func equivalentCommands(
            service: String,
            device: String,
            addressing: LinuxHostBridgeAddressing,
            address: String?,
            gateway: String?,
            dns: [String],
        ) -> [String] {
            guard case let .success(plan) = HostInterfaceAddressApply.resolveLegacy(
                addressing: addressing,
                address: address,
                gateway: gateway,
                dns: dns,
            ) else {
                return ["# invalid address plan"]
            }
            return equivalentCommands(service: service, device: device, plan: plan)
        }

        public static func equivalentCommands(
            service: String,
            device: String,
            plan: HostInterfaceAddressApplyPlan,
        ) -> [String] {
            var lines = [
                "# Device address on \(device) (\(service)) — not a Workload guest address.",
                "networksetup -listallhardwareports",
            ]
            if plan.dhcpEnabled {
                lines.append("sudo networksetup -setdhcp \"\(service)\"")
            } else if let primary = plan.primaryStaticCIDR {
                let parsed = (try? parseStaticAddress(primary)) ?? (ip: "192.168.1.10", mask: "255.255.255.0")
                let gw = plan.gateway ?? "192.168.1.1"
                lines.append(
                    "sudo networksetup -setmanual \"\(service)\" \(parsed.ip) \(parsed.mask) \(gw)",
                )
            }
            for cidr in plan.dhcpEnabled ? plan.staticCIDRs : plan.aliasCIDRs {
                let parsed = (try? parseStaticAddress(cidr)) ?? (ip: cidr, mask: "255.255.255.0")
                lines.append("sudo ifconfig \(device) alias \(parsed.ip) netmask \(parsed.mask)")
            }
            if !plan.dns.isEmpty {
                lines.append("sudo networksetup -setdnsservers \"\(service)\" \(plan.dns.joined(separator: " "))")
            }
            lines.append("sudo networksetup -setdhcp \"\(service)\"  # revert to DHCP")
            return lines
        }
    }

#endif
