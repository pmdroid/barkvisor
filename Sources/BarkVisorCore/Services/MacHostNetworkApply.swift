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
            public var appliedAliasCIDRs: [String]
            public var removedAliasCIDRs: [String]
            public var touchedDHCP: Bool
            public var touchedManual: Bool
            public var touchedDNS: Bool

            public init(
                device: String,
                service: String,
                infoText: String,
                dnsServers: [String],
                appliedAliasCIDRs: [String] = [],
                removedAliasCIDRs: [String] = [],
                touchedDHCP: Bool = false,
                touchedManual: Bool = false,
                touchedDNS: Bool = false,
            ) {
                self.device = device
                self.service = service
                self.infoText = infoText
                self.dnsServers = dnsServers
                self.appliedAliasCIDRs = appliedAliasCIDRs
                self.removedAliasCIDRs = removedAliasCIDRs
                self.touchedDHCP = touchedDHCP
                self.touchedManual = touchedManual
                self.touchedDNS = touchedDNS
            }

            enum CodingKeys: String, CodingKey {
                case device, service, infoText, dnsServers, appliedAliasCIDRs, removedAliasCIDRs
                case touchedDHCP, touchedManual, touchedDNS
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                device = try container.decode(String.self, forKey: .device)
                service = try container.decode(String.self, forKey: .service)
                infoText = try container.decode(String.self, forKey: .infoText)
                dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
                appliedAliasCIDRs = try container.decodeIfPresent([String].self, forKey: .appliedAliasCIDRs) ?? []
                removedAliasCIDRs = try container.decodeIfPresent([String].self, forKey: .removedAliasCIDRs) ?? []
                touchedDHCP = try container.decodeIfPresent(Bool.self, forKey: .touchedDHCP) ?? false
                touchedManual = try container.decodeIfPresent(Bool.self, forKey: .touchedManual) ?? false
                touchedDNS = try container.decodeIfPresent(Bool.self, forKey: .touchedDNS) ?? false
            }
        }

        public struct AddressDelta: Sendable, Equatable {
            public var addAliasCIDRs: [String]
            public var removeAliasIPs: [String]
            public var setDHCP: Bool
            public var setManual: (ip: String, mask: String, gateway: String)?
            public var setDNS: [String]?

            public init(
                addAliasCIDRs: [String] = [],
                removeAliasIPs: [String] = [],
                setDHCP: Bool = false,
                setManual: (ip: String, mask: String, gateway: String)? = nil,
                setDNS: [String]? = nil,
            ) {
                self.addAliasCIDRs = addAliasCIDRs
                self.removeAliasIPs = removeAliasIPs
                self.setDHCP = setDHCP
                self.setManual = setManual
                self.setDNS = setDNS
            }

            public static func == (lhs: AddressDelta, rhs: AddressDelta) -> Bool {
                lhs.addAliasCIDRs == rhs.addAliasCIDRs
                    && lhs.removeAliasIPs == rhs.removeAliasIPs
                    && lhs.setDHCP == rhs.setDHCP
                    && lhs.setManual?.ip == rhs.setManual?.ip
                    && lhs.setManual?.mask == rhs.setManual?.mask
                    && lhs.setManual?.gateway == rhs.setManual?.gateway
                    && lhs.setDNS == rhs.setDNS
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
            let delta = try addressDelta(device: device, service: service, plan: plan, run: run)
            try apply(device: device, service: service, delta: delta, run: run)
        }

        public static func apply(
            device: String,
            service: String,
            delta: AddressDelta,
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 30)
            },
        ) throws {
            var marker = readMarker(device: device)
            if delta.setDHCP {
                let result = try run(networksetupPath, ["-setdhcp", service])
                guard result.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setdhcp failed: \(result.stderrString)",
                    )
                }
                marker?.touchedDHCP = true
            }
            if let manual = delta.setManual {
                let result = try run(networksetupPath, [
                    "-setmanual", service, manual.ip, manual.mask, manual.gateway,
                ])
                guard result.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setmanual failed: \(result.stderrString)",
                    )
                }
                marker?.touchedManual = true
            }
            let liveBeforeRemove = delta.removeAliasIPs.isEmpty
                ? []
                : try listIPv4Rows(device: device, run: run)
            for ip in delta.removeAliasIPs {
                let aliasResult = try run("/sbin/ifconfig", [device, "-alias", ip])
                guard aliasResult.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "ifconfig -alias failed for \(ip): \(aliasResult.stderrString)",
                    )
                }
            }
            if !delta.removeAliasIPs.isEmpty {
                let removed = liveBeforeRemove
                    .filter { delta.removeAliasIPs.contains($0.ip) }
                    .map(\.cidr)
                if var snapshot = marker {
                    snapshot.removedAliasCIDRs = Array(Set(snapshot.removedAliasCIDRs + removed))
                    snapshot.appliedAliasCIDRs.removeAll { cidr in
                        guard let parsed = try? parseStaticAddress(cidr) else { return false }
                        return delta.removeAliasIPs.contains(parsed.ip)
                    }
                    marker = snapshot
                }
            }
            for cidr in delta.addAliasCIDRs {
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
            if !delta.addAliasCIDRs.isEmpty, var snapshot = marker {
                snapshot.appliedAliasCIDRs = Array(Set(snapshot.appliedAliasCIDRs + delta.addAliasCIDRs))
                marker = snapshot
            }
            if let dns = delta.setDNS {
                let dnsResult = try run(networksetupPath, ["-setdnsservers", service] + dns)
                guard dnsResult.succeeded else {
                    throw BarkVisorError.preconditionFailed(
                        "networksetup -setdnsservers failed: \(dnsResult.stderrString)",
                    )
                }
                marker?.touchedDNS = true
            }
            if let marker {
                try writeMarker(marker)
            }
        }

        public static func addressDelta(
            device: String,
            service: String,
            plan: HostInterfaceAddressApplyPlan,
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 15)
            },
        ) throws -> AddressDelta {
            let info = try run(networksetupPath, ["-getinfo", service])
            let infoText = info.succeeded ? info.stdoutString : ""
            let currentDHCP = infoText.lowercased().contains("dhcp configuration")
            let currentIP = parseInfoValue(infoText, key: "IP address")
            let live = try listIPv4Rows(device: device, run: run)
            let aliasTargets = plan.dhcpEnabled ? plan.staticCIDRs : plan.aliasCIDRs
            let plannedAliasIPs = Set(aliasTargets.compactMap { try? parseStaticAddress($0).ip })
            let primaryIP: String? = if plan.dhcpEnabled {
                currentIP
            } else if let primary = plan.primaryStaticCIDR {
                try parseStaticAddress(primary).ip
            } else {
                nil
            }
            let skipStale = plan.dhcpEnabled && primaryIP == nil
            let ownedIPs = Set((readMarker(device: device)?.appliedAliasCIDRs ?? []).compactMap {
                try? parseStaticAddress($0).ip
            })
            var removeAliasIPs: [String] = []
            if !skipStale {
                for row in live {
                    if row.ip == primaryIP { continue }
                    if plannedAliasIPs.contains(row.ip) { continue }
                    guard ownedIPs.contains(row.ip) else { continue }
                    removeAliasIPs.append(row.ip)
                }
            }
            var addAliasCIDRs: [String] = []
            for cidr in aliasTargets {
                let ip = try parseStaticAddress(cidr).ip
                if live.contains(where: { $0.ip == ip }) { continue }
                addAliasCIDRs.append(cidr)
            }
            var setDHCP = false
            var setManual: (ip: String, mask: String, gateway: String)?
            if plan.dhcpEnabled {
                setDHCP = !currentDHCP
            } else if let primary = plan.primaryStaticCIDR {
                let parsed = try parseStaticAddress(primary)
                guard let gateway = plan.gateway, !gateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BarkVisorError.badRequest("Static host address needs gateway")
                }
                try validateIPv4(gateway, label: "gateway")
                let already = currentIP == parsed.ip && !currentDHCP
                if !already {
                    setManual = (parsed.ip, parsed.mask, gateway)
                }
            }
            var setDNS: [String]?
            if !plan.dns.isEmpty {
                let dns = try run(networksetupPath, ["-getdnsservers", service])
                let current = dns.succeeded ? parseDNSServers(dns.stdoutString) : []
                if current != plan.dns {
                    setDNS = plan.dns
                }
            }
            return AddressDelta(
                addAliasCIDRs: addAliasCIDRs,
                removeAliasIPs: removeAliasIPs,
                setDHCP: setDHCP,
                setManual: setManual,
                setDNS: setDNS,
            )
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
            if marker.touchedDHCP || marker.touchedManual {
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
                }
            }
            if marker.touchedDNS {
                if marker.dnsServers.isEmpty {
                    _ = try? run(networksetupPath, ["-setdnsservers", marker.service, "Empty"])
                } else {
                    _ = try? run(networksetupPath, ["-setdnsservers", marker.service] + marker.dnsServers)
                }
            }
            for cidr in marker.removedAliasCIDRs {
                let parsed = try parseStaticAddress(cidr)
                _ = try run(
                    "/sbin/ifconfig",
                    [device, "alias", parsed.ip, "netmask", parsed.mask],
                )
            }
            removeMarker(device: device)
            return true
        }

        public static func revertDelta(marker: Snapshot) -> AddressDelta {
            var setManual: (ip: String, mask: String, gateway: String)?
            var setDHCP = false
            if marker.touchedDHCP || marker.touchedManual {
                let lower = marker.infoText.lowercased()
                if lower.contains("dhcp configuration") {
                    setDHCP = true
                } else if let ip = parseInfoValue(marker.infoText, key: "IP address"),
                          let mask = parseInfoValue(marker.infoText, key: "Subnet mask"),
                          let router = parseInfoValue(marker.infoText, key: "Router") {
                    setManual = (ip, mask, router)
                }
            }
            var setDNS: [String]?
            if marker.touchedDNS {
                setDNS = marker.dnsServers.isEmpty ? ["Empty"] : marker.dnsServers
            }
            return AddressDelta(
                addAliasCIDRs: marker.removedAliasCIDRs,
                removeAliasIPs: marker.appliedAliasCIDRs.compactMap { try? parseStaticAddress($0).ip },
                setDHCP: setDHCP,
                setManual: setManual,
                setDNS: setDNS,
            )
        }

        static func listIPv4Addresses(
            device: String,
            run: (String, [String]) throws -> CommandResult,
        ) throws -> [String] {
            try listIPv4Rows(device: device, run: run).map(\.ip)
        }

        static func listIPv4Rows(
            device: String,
            run: (String, [String]) throws -> CommandResult,
        ) throws -> [(ip: String, cidr: String)] {
            let result = try run("/sbin/ifconfig", [device])
            guard result.succeeded else { return [] }
            var rows: [(ip: String, cidr: String)] = []
            for raw in result.stdoutString.split(whereSeparator: \.isNewline) {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("inet ") else { continue }
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 2, parts[1].contains(".") else { continue }
                let ip = parts[1]
                var prefix = 32
                if let idx = parts.firstIndex(of: "netmask"), idx + 1 < parts.count,
                   let parsed = prefixLength(fromNetmask: parts[idx + 1]) {
                    prefix = parsed
                }
                rows.append((ip, "\(ip)/\(prefix)"))
            }
            return rows
        }

        static func prefixLength(fromNetmask raw: String) -> Int? {
            if raw.hasPrefix("0x"), let value = UInt32(raw.dropFirst(2), radix: 16) {
                return value.nonzeroBitCount
            }
            let octets = raw.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { return nil }
            var bits: UInt32 = 0
            for octet in octets {
                bits = (bits << 8) | UInt32(octet)
            }
            return bits.nonzeroBitCount
        }

        static func staleAliasCIDRs(
            device: String,
            primaryIP: String?,
            plannedAliasIPs: Set<String>,
            run: (String, [String]) throws -> CommandResult,
        ) throws -> [String] {
            try listIPv4Rows(device: device, run: run).compactMap { row in
                if row.ip == primaryIP { return nil }
                if plannedAliasIPs.contains(row.ip) { return nil }
                return row.cidr
            }
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
            delta: AddressDelta,
        ) -> [String] {
            var lines: [String] = []
            if delta.setDHCP {
                lines.append("sudo networksetup -setdhcp \"\(service)\"")
            }
            if let manual = delta.setManual {
                lines.append(
                    "sudo networksetup -setmanual \"\(service)\" \(manual.ip) \(manual.mask) \(manual.gateway)",
                )
            }
            for ip in delta.removeAliasIPs {
                lines.append("sudo ifconfig \(device) -alias \(ip)")
            }
            for cidr in delta.addAliasCIDRs {
                let parsed = (try? parseStaticAddress(cidr)) ?? (ip: cidr, mask: "255.255.255.0")
                lines.append("sudo ifconfig \(device) alias \(parsed.ip) netmask \(parsed.mask)")
            }
            if let dns = delta.setDNS, !dns.isEmpty {
                lines.append(
                    "sudo networksetup -setdnsservers \"\(service)\" \(dns.joined(separator: " "))",
                )
            }
            return lines
        }

        public static func describeDelta(
            _ delta: AddressDelta,
            service: String,
            device: String,
        ) -> [String] {
            var lines: [String] = []
            if delta.setDHCP {
                lines.append("Set \(service) (\(device)) IPv4: DHCP")
            }
            if let manual = delta.setManual {
                lines.append("Set \(service) (\(device)) IPv4: static \(manual.ip)")
            }
            for ip in delta.removeAliasIPs {
                lines.append("Remove \(service) (\(device)) alias \(ip)")
            }
            for cidr in delta.addAliasCIDRs {
                lines.append("Add \(service) (\(device)) static alias \(cidr)")
            }
            if let dns = delta.setDNS, !dns.isEmpty {
                lines.append("DNS: \(dns.joined(separator: ", "))")
            }
            return lines
        }

        public static func equivalentCommands(
            service: String,
            device: String,
            plan: HostInterfaceAddressApplyPlan,
        ) -> [String] {
            var lines: [String] = []
            if !plan.dhcpEnabled, let primary = plan.primaryStaticCIDR {
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
            return lines
        }
    }

#endif
