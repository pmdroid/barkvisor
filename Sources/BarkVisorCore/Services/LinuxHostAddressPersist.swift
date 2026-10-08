import Foundation

public enum LinuxHostAddressPersist {
    public static func networkdSearchDirectories(
        etc: String = LinuxHostBridgeApply.systemdNetworkDir,
        run: String = "/run/systemd/network",
        lib: String = "/lib/systemd/network",
    ) -> [String] {
        [run, etc, lib, "/usr/lib/systemd/network"]
    }

    public static func networkdMatches(text: String, interface: String) -> Bool {
        if LinuxHostBridgeApply.hasNetworkAssignment(text, key: "Name", value: interface) {
            return true
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Name=") else { continue }
            let pattern = String(line.dropFirst("Name=".count))
            if pattern == "*" || pattern == "en*" || pattern == "eth*" {
                if pattern == "*" { return true }
                if interface.hasPrefix(String(pattern.dropLast())) { return true }
            }
        }
        return false
    }

    public static func networkdMatchingNetworkFile(
        interface: String,
        directories: [String],
    ) -> String? {
        var matches: [String] = []
        for dir in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in names where name.hasSuffix(".network") {
                let path = "\(dir)/\(name)"
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      networkdMatches(text: text, interface: interface) else { continue }
                matches.append(path)
            }
        }
        return matches.min { lhs, rhs in
            URL(fileURLWithPath: lhs).lastPathComponent < URL(fileURLWithPath: rhs).lastPathComponent
        }
    }

    public static func networkdMatchingNetworkFile(
        interface: String,
        dir: String = LinuxHostBridgeApply.systemdNetworkDir,
    ) -> String? {
        networkdMatchingNetworkFile(interface: interface, directories: [dir])
    }

    public static func networkdAliasDropInPath(matchFile: String) -> String {
        "\(matchFile).d/90-barkvisor-aliases.conf"
    }

    public static func networkdAliasUnitPath(
        interface: String,
        dir: String = LinuxHostBridgeApply.systemdNetworkDir,
    ) -> String {
        "\(dir)/90-barkvisor-\(interface)-aliases.network"
    }

    public static func networkdAliasDropInBody(cidrs: [String]) -> String {
        var body = "# managed-by: barkvisor\n[Network]\n"
        for cidr in cidrs {
            body += "Address=\(cidr)\n"
        }
        return body
    }

    public static func networkdAliasUnitBody(interface: String, cidrs: [String]) -> String {
        var body = "# managed-by: barkvisor\n[Match]\nName=\(interface)\n\n[Network]\n"
        for cidr in cidrs {
            body += "Address=\(cidr)\n"
        }
        return body
    }

    public static func netplanAliasPath(interface: String) -> String {
        "/etc/netplan/90-barkvisor-\(interface)-aliases.yaml"
    }

    public static func netplanAliasYAML(interface: String, cidrs: [String]) -> String {
        let kind = interface.hasPrefix("br") ? "bridges" : "ethernets"
        let lines = cidrs.map { "      - \($0)" }.joined(separator: "\n")
        return """
        # managed-by: barkvisor
        network:
          version: 2
          \(kind):
            \(interface):
              addresses:
        \(lines)
        """
    }

    public static func persistFiles(
        interface: String,
        cidrs: [String],
        backend: LinuxNetworkBackend,
        dir: String = LinuxHostBridgeApply.systemdNetworkDir,
        directories: [String]? = nil,
    ) -> [(path: String, body: String)] {
        switch backend {
        case .networkManager, .ifupdown, .unknown:
            return []
        case .systemdNetworkd:
            if let match = networkdMatchingNetworkFile(interface: interface, directories: directories ?? networkdSearchDirectories(etc: dir)) {
                return [(networkdAliasDropInPath(matchFile: match), networkdAliasDropInBody(cidrs: cidrs))]
            }
            return [(
                networkdAliasUnitPath(interface: interface, dir: dir),
                networkdAliasUnitBody(interface: interface, cidrs: cidrs),
            )]
        case .netplan:
            return [(netplanAliasPath(interface: interface), netplanAliasYAML(interface: interface, cidrs: cidrs))]
        }
    }

    public static func migrateAliasUnitOntoPort(
        interface: String,
        dir: String = LinuxHostBridgeApply.systemdNetworkDir,
    ) throws {
        let alias = networkdAliasUnitPath(interface: interface, dir: dir)
        let port = "\(dir)/90-barkvisor-\(interface).network"
        guard FileManager.default.fileExists(atPath: alias) else { return }
        guard FileManager.default.fileExists(atPath: port) else { return }
        let body = (try? String(contentsOfFile: alias, encoding: .utf8)) ?? ""
        var cidrs: [String] = []
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Address=") {
                let value = String(line.dropFirst("Address=".count))
                if !value.isEmpty { cidrs.append(value) }
            }
        }
        if !cidrs.isEmpty {
            let drop = networkdAliasDropInPath(matchFile: port)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: drop).deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try networkdAliasDropInBody(cidrs: cidrs).write(
                toFile: drop,
                atomically: true,
                encoding: .utf8,
            )
        }
        try FileManager.default.removeItem(atPath: alias)
    }

    public static func ipAddrAddAlreadyPresent(_ stderr: String) -> Bool {
        let err = stderr.lowercased()
        return err.contains("already assigned")
            || err.contains("file exists")
            || err.contains("exists")
    }

    public static func cidrsNotOnDevice(_ desired: [String], live: [String]) -> [String] {
        let present = Set(live.flatMap { cidr -> [String] in
            let ip = cidr.split(separator: "/").first.map(String.init) ?? cidr
            return [cidr, ip]
        })
        return desired.filter { cidr in
            let ip = cidr.split(separator: "/").first.map(String.init) ?? cidr
            return !present.contains(cidr) && !present.contains(ip)
        }
    }

    public static func cidrsToRemove(
        desired: [String],
        live: [String],
        keep: [String] = [],
    ) -> [String] {
        let desiredKeys = Set(desired.flatMap { cidr -> [String] in
            let ip = cidr.split(separator: "/").first.map(String.init) ?? cidr
            return [cidr, ip]
        })
        let keepKeys = Set(keep.flatMap { cidr -> [String] in
            let ip = cidr.split(separator: "/").first.map(String.init) ?? cidr
            return [cidr, ip]
        })
        return live.filter { cidr in
            let ip = cidr.split(separator: "/").first.map(String.init) ?? cidr
            if desiredKeys.contains(cidr) || desiredKeys.contains(ip) { return false }
            if keepKeys.contains(cidr) || keepKeys.contains(ip) { return false }
            return true
        }
    }

    public static func previewCommands(
        interface: String,
        cidrs: [String],
        backend: LinuxNetworkBackend,
        liveCIDRs: [String] = [],
        keepCIDRs: [String] = [],
    ) -> [LinuxHostBridgeChange] {
        let add = liveCIDRs.isEmpty ? cidrs : cidrsNotOnDevice(cidrs, live: liveCIDRs)
        let remove = liveCIDRs.isEmpty ? [] : cidrsToRemove(desired: cidrs, live: liveCIDRs, keep: keepCIDRs)
        var rows: [LinuxHostBridgeChange] = []
        let files = persistFiles(interface: interface, cidrs: cidrs, backend: backend)
        if cidrs.isEmpty {
            for file in files {
                rows.append(LinuxHostBridgeChange(
                    description: "Remove extra IP persist file \(file.path)",
                    command: "sudo rm -f \(file.path)",
                ))
            }
        } else {
            for file in files {
                rows.append(LinuxHostBridgeChange(
                    description: "Persist extra IPs in \(file.path)",
                    command: "sudo tee \(file.path)",
                ))
            }
        }
        if backend == .networkManager {
            for cidr in add {
                rows.append(LinuxHostBridgeChange(
                    description: "Persist \(cidr) on \(interface) via NetworkManager",
                    command: "sudo nmcli connection modify \(interface) +ipv4.addresses \(cidr)",
                ))
            }
            for cidr in remove {
                rows.append(LinuxHostBridgeChange(
                    description: "Drop \(cidr) on \(interface) via NetworkManager",
                    command: "sudo nmcli connection modify \(interface) -ipv4.addresses \(cidr)",
                ))
            }
        }
        if backend == .systemdNetworkd {
            rows.append(LinuxHostBridgeChange(
                description: "Reload systemd-networkd",
                command: "sudo networkctl reload",
            ))
        }
        for cidr in add {
            rows.append(LinuxHostBridgeChange(
                description: "Add \(interface) address \(cidr)",
                command: "sudo ip addr add \(cidr) dev \(interface)",
            ))
        }
        for cidr in remove {
            rows.append(LinuxHostBridgeChange(
                description: "Remove \(interface) address \(cidr)",
                command: "sudo ip addr del \(cidr) dev \(interface)",
            ))
        }
        return rows
    }
}
