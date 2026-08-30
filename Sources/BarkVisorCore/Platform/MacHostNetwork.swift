import Foundation

public enum MacHostNetwork {
    public static let ethernetPlaceholder = "Ethernet"

    public static func parseHardwarePorts(_ output: String) -> [(port: String, device: String)] {
        var currentPort: String?
        var result: [(port: String, device: String)] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("VLAN") {
                break
            }
            if line.hasPrefix("Hardware Port:") {
                currentPort = String(line.dropFirst("Hardware Port:".count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("Device:"), let port = currentPort, !port.isEmpty else {
                continue
            }
            let device = String(line.dropFirst("Device:".count))
                .trimmingCharacters(in: .whitespaces)
            currentPort = nil
            guard !device.isEmpty else { continue }
            result.append((port: port, device: device))
        }
        return result
    }

    public static func serviceName(
        forDevice device: String?,
        ports: [(port: String, device: String)],
    ) -> String {
        if let device, !device.isEmpty,
           let match = ports.first(where: { $0.device == device }) {
            return match.port
        }
        if let wired = ports.first(where: { isWiredUplink($0.port) }) {
            return wired.port
        }
        return ethernetPlaceholder
    }

    public static func resolvedService(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? ethernetPlaceholder : trimmed
    }

    public static func quotedService(_ name: String?) -> String {
        let escaped = resolvedService(name)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public static func deviceAddressCommands(service: String?) -> String {
        let quoted = quotedService(service)
        return [
            "# Host address on this Device (DHCP or static). Guest static IP is separate.",
            "sudo networksetup -setdhcp \(quoted)",
            "sudo networksetup -setmanual \(quoted) 192.168.1.10 255.255.255.0 192.168.1.1",
        ].joined(separator: "\n")
    }

    public static func deviceAddressRemediation(service: String?) -> HostBridgeRemediation {
        HostBridgeRemediation(
            id: "device-address",
            label: "Device address",
            commands: deviceAddressCommands(service: service),
        )
    }

    public static func liveHardwarePortsOutput() -> String? {
        #if os(macOS)
            guard let result = try? PlatformProcess.run(
                path: "/usr/sbin/networksetup",
                arguments: ["-listallhardwareports"],
                timeout: 5,
            ), result.succeeded else {
                return nil
            }
            let text = result.stdoutString
            return text.isEmpty ? nil : text
        #else
            return nil
        #endif
    }

    private static func isWiredUplink(_ port: String) -> Bool {
        let lower = port.lowercased()
        if lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("airport")
            || lower.contains("wireless") {
            return false
        }
        if lower.contains("thunderbolt bridge") || lower.contains("bluetooth") {
            return false
        }
        return true
    }
}
