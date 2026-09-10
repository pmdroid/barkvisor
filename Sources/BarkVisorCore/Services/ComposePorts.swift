import Foundation

public struct ComposePortBinding: Equatable, Sendable {
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var proto: String

    public init(hostIP: String, hostPort: Int, containerPort: Int, proto: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }
}

enum ComposePorts {
    struct Rewrite {
        var mapping: [[String: Any]]
        var published: [PublishedPort]
    }

    static func rewriteHostNetwork(_ service: inout [String: Any]) throws {
        guard let mode = stringValue(service["network_mode"])?.lowercased(), mode == "host" else {
            return
        }
        let image = stringValue(service["image"]) ?? ""
        guard isPlexImage(image) else { return }
        service.removeValue(forKey: "network_mode")
        if try parsePorts(service["ports"]).isEmpty {
            service["ports"] = ["32400:32400"]
        }
    }

    static func rewritePublishedPorts(_ value: Any?, bindHost: String?) throws -> Rewrite {
        if let value, !(value is NSNull), !(value is [Any]) {
            throw BarkVisorError.badRequest("unsupported compose feature: ports")
        }
        let parsed = try parsePorts(value)
        if parsed.isEmpty {
            if let array = value as? [Any], !array.isEmpty {
                throw BarkVisorError.badRequest("unsupported compose feature: ports")
            }
            return Rewrite(mapping: [], published: [])
        }
        _ = bindHost
        let host = "0.0.0.0"
        var mapping: [[String: Any]] = []
        var published: [PublishedPort] = []
        for port in parsed {
            mapping.append([
                "target": port.containerPort,
                "published": port.hostPort,
                "protocol": port.proto,
                "host_ip": host,
            ])
            published.append(
                PublishedPort(
                    hostPort: port.hostPort,
                    containerPort: port.containerPort,
                    proto: port.proto,
                    hostAddress: host,
                ),
            )
        }
        return Rewrite(mapping: mapping, published: published)
    }

    static func parseInspectBindings(_ data: Data) throws -> [ComposePortBinding] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BarkVisorError.internalError("docker inspect is not valid JSON")
        }
        let containers: [Any] = if let array = json as? [Any] {
            array
        } else {
            [json]
        }
        var bindings: [ComposePortBinding] = []
        for container in containers {
            guard let object = asObject(container) else { continue }
            let settings = asObject(object["NetworkSettings"]) ?? [:]
            let ports = asObject(settings["Ports"]) ?? [:]
            for (key, raw) in ports {
                let proto: String
                let containerPort: Int
                if let slash = key.lastIndex(of: "/") {
                    containerPort = Int(key[..<slash]) ?? 0
                    proto = String(key[key.index(after: slash)...]).lowercased()
                } else {
                    containerPort = Int(key) ?? 0
                    proto = "tcp"
                }
                guard (1 ... 65_535).contains(containerPort) else { continue }
                let rows: [Any]
                if let array = raw as? [Any] {
                    rows = array
                } else {
                    continue
                }
                for row in rows {
                    guard let bind = asObject(row) else { continue }
                    let hostIP = stringValue(bind["HostIp"]) ?? ""
                    let hostPort = intValue(bind["HostPort"]) ?? 0
                    guard (1 ... 65_535).contains(hostPort) else { continue }
                    bindings.append(
                        ComposePortBinding(
                            hostIP: hostIP,
                            hostPort: hostPort,
                            containerPort: containerPort,
                            proto: proto,
                        ),
                    )
                }
            }
        }
        return bindings
    }

    static func requireLANHostIP(
        _ bindings: [ComposePortBinding],
        bindHost: String,
        expected: [PublishedPort],
        allowWildcard: Bool,
    ) throws {
        if expected.isEmpty { return }
        _ = bindHost
        _ = allowWildcard
        for port in expected {
            let proto = port.proto.lowercased()
            let found = bindings.contains {
                $0.hostPort == port.hostPort && $0.proto == proto
            }
            if !found {
                throw BarkVisorError.internalError(
                    "docker inspect missing \(port.hostPort)/\(proto)",
                )
            }
        }
    }

    static func isWildcardHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        return lower == "0.0.0.0" || lower == "::" || lower == "*" || lower == "[::]"
    }

    static func requireBindHost(_ host: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isWildcardHost(trimmed) {
            throw BarkVisorError.badRequest("No LAN address to bind published ports")
        }
        if trimmed.contains(":") {
            throw BarkVisorError.badRequest("No LAN address to bind published ports")
        }
    }

    static func isPlexImage(_ image: String) -> Bool {
        let lower = image.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noDigest = lower.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? lower
        let lastPath = noDigest.split(separator: "/").last.map(String.init) ?? noDigest
        let name = lastPath.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? lastPath
        return name == "plex" || name == "pms-docker"
    }

    static func parsePorts(_ value: Any?) throws -> [PublishedPort] {
        guard let value, !(value is NSNull) else { return [] }
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else {
            throw BarkVisorError.badRequest("unsupported compose feature: ports")
        }
        var result: [PublishedPort] = []
        for item in items {
            if let text = stringValue(item) {
                guard let port = parsePortString(text) else {
                    throw BarkVisorError.badRequest("unsupported compose feature: ports")
                }
                result.append(port)
                continue
            }
            if let object = asObject(item) {
                let published = intValue(object["published"]) ?? intValue(object["host_port"])
                let target = intValue(object["target"]) ?? intValue(object["container_port"])
                let proto = (stringValue(object["protocol"]) ?? "tcp").lowercased()
                guard let published, let target, (1 ... 65_535).contains(published),
                      (1 ... 65_535).contains(target)
                else {
                    throw BarkVisorError.badRequest("unsupported compose feature: ports")
                }
                result.append(
                    PublishedPort(hostPort: published, containerPort: target, proto: proto),
                )
                continue
            }
            throw BarkVisorError.badRequest("unsupported compose feature: ports")
        }
        return result
    }

    static func parsePortString(_ text: String) -> PublishedPort? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var proto = "tcp"
        if let slash = raw.lastIndex(of: "/") {
            proto = String(raw[raw.index(after: slash)...]).lowercased()
            raw = String(raw[..<slash])
        }
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]") else { return nil }
            raw = String(raw[raw.index(after: close)...])
            if raw.hasPrefix(":") { raw = String(raw.dropFirst()) }
        }
        let parts = raw.split(separator: ":").map(String.init)
        let host: Int?
        let container: Int?
        switch parts.count {
        case 1:
            host = Int(parts[0])
            container = host
        case 2:
            host = Int(parts[0])
            container = Int(parts[1])
        case 3:
            host = Int(parts[1])
            container = Int(parts[2])
        default:
            return nil
        }
        guard let host, let container, (1 ... 65_535).contains(host), (1 ... 65_535).contains(container)
        else { return nil }
        return PublishedPort(hostPort: host, containerPort: container, proto: proto)
    }

    private static func asObject(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let dict = value as? [AnyHashable: Any] else { return nil }
        var out: [String: Any] = [:]
        for (key, nested) in dict {
            out[String(describing: key)] = nested
        }
        return out
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let int = value as? Int { return String(int) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
