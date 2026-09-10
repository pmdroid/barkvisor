import Foundation
import Yams

public struct ComposeRender: Equatable, Sendable {
    public var yaml: String
    public var publishedPorts: [PublishedPort]
    public var namedVolumes: [String]

    public init(yaml: String, publishedPorts: [PublishedPort], namedVolumes: [String]) {
        self.yaml = yaml
        self.publishedPorts = publishedPorts
        self.namedVolumes = namedVolumes
    }
}

public enum ComposeAllowlist {
    public static let workloadLabelKey = "barkvisor.workload"
    public static let kindLabelKey = "barkvisor.kind"

    private static let allowedTopLevel: Set<String> = [
        "services", "volumes", "name", "version",
    ]
    private static let allowedServiceKeys: Set<String> = [
        "image", "ports", "environment", "env_file", "volumes", "restart", "user",
        "depends_on", "healthcheck", "command", "container_name", "labels",
        "entrypoint", "working_dir", "hostname", "expose", "pull_policy",
    ]

    public static func render(
        yaml: String,
        workloadID: String,
        stateDir: URL,
    ) throws -> ComposeRender {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BarkVisorError.badRequest("spec.compose is required")
        }
        let loaded: Any
        do {
            loaded = try Yams.load(yaml: trimmed) ?? [String: Any]()
        } catch {
            throw BarkVisorError.badRequest("spec.compose is not valid YAML")
        }
        guard var root = asObject(loaded) else {
            throw BarkVisorError.badRequest("spec.compose must be a mapping")
        }
        try rejectTopLevel(root)
        try rejectInterpolation(root)
        guard var services = asObject(root["services"]), !services.isEmpty else {
            throw BarkVisorError.badRequest("spec.compose must declare services")
        }
        var published: [PublishedPort] = []
        var named: [String] = []
        let volumeRoot = stateDir.appendingPathComponent("volumes", isDirectory: true)
        _ = try requirePath(under: stateDir, candidate: volumeRoot)
        for name in services.keys.sorted() {
            guard var service = asObject(services[name]) else {
                throw BarkVisorError.badRequest("unsupported compose feature: services.\(name)")
            }
            try rejectService(service, serviceName: name)
            if service["env_file"] != nil {
                service["env_file"] = ".env"
            }
            if let environment = service["environment"] {
                service["environment"] = try rewriteEnvironment(environment)
            }
            let rewritten = try rewriteVolumes(
                service["volumes"],
                serviceName: name,
                volumeRoot: volumeRoot,
            )
            service["volumes"] = rewritten.mapping
            named.append(contentsOf: rewritten.named)
            try published.append(contentsOf: parsePorts(service["ports"]))
            service["container_name"] = containerName(workloadID: workloadID, service: name)
            service["labels"] = mergeLabels(service["labels"], workloadID: workloadID)
            if let depends = service["depends_on"] {
                try validateDependsOn(depends)
            }
            services[name] = service
        }
        root["services"] = services
        if root["volumes"] != nil {
            var declared: [String: Any] = [:]
            for name in Set(named) {
                declared[name] = [String: Any]()
            }
            if declared.isEmpty {
                root.removeValue(forKey: "volumes")
            } else {
                root["volumes"] = declared
            }
        }
        let dumped: String
        do {
            dumped = try Yams.dump(object: root, width: -1)
        } catch {
            throw BarkVisorError.badRequest("spec.compose could not be rewritten")
        }
        return ComposeRender(
            yaml: dumped,
            publishedPorts: published,
            namedVolumes: Array(Set(named)).sorted(),
        )
    }

    public static func containerName(workloadID: String, service: String) -> String {
        "bv-\(workloadID)-\(service)"
    }

    public static func firstImage(yaml: String?) -> String? {
        guard let yaml, let loaded = try? Yams.load(yaml: yaml) else { return nil }
        guard let root = loaded as? [String: Any] else { return nil }
        guard let services = root["services"] as? [String: Any] else { return nil }
        for key in services.keys.sorted() {
            if let service = services[key] as? [String: Any], let image = service["image"] as? String {
                return image
            }
        }
        return nil
    }

    private static func rejectInterpolation(_ value: Any) throws {
        if let text = value as? String, text.contains("$") {
            throw BarkVisorError.badRequest("unsupported compose feature: interpolation")
        }
        if let array = value as? [Any] {
            for item in array {
                try rejectInterpolation(item)
            }
            return
        }
        if let object = asObject(value) {
            for (key, nested) in object {
                if key.contains("$") {
                    throw BarkVisorError.badRequest("unsupported compose feature: interpolation")
                }
                try rejectInterpolation(nested)
            }
        }
    }

    private static func rejectTopLevel(_ root: [String: Any]) throws {
        for key in root.keys {
            if key.hasPrefix("x-") { continue }
            if key == "secrets" || key == "configs" {
                throw BarkVisorError.badRequest("unsupported compose feature: \(key)")
            }
            if key == "networks" {
                throw BarkVisorError.badRequest("unsupported compose feature: networks")
            }
            if !allowedTopLevel.contains(key) {
                throw BarkVisorError.badRequest("unsupported compose feature: \(key)")
            }
        }
        if root["build"] != nil {
            throw BarkVisorError.badRequest("unsupported compose feature: build")
        }
    }

    private static func rejectService(_ service: [String: Any], serviceName: String) throws {
        if isTruthy(service["privileged"]) {
            throw BarkVisorError.badRequest("unsupported compose feature: privileged")
        }
        if let mode = stringValue(service["network_mode"])?.lowercased(), mode == "host" {
            throw BarkVisorError.badRequest("unsupported compose feature: host network")
        }
        if service["network_mode"] != nil {
            throw BarkVisorError.badRequest("unsupported compose feature: network_mode")
        }
        if let pid = stringValue(service["pid"])?.lowercased(), pid == "host" {
            throw BarkVisorError.badRequest("unsupported compose feature: pid host")
        }
        if service["pid"] != nil {
            throw BarkVisorError.badRequest("unsupported compose feature: pid")
        }
        if let caps = service["cap_add"], !isEmptyValue(caps) {
            throw BarkVisorError.badRequest("unsupported compose feature: cap_add")
        }
        if let devices = service["devices"], !isEmptyValue(devices) {
            throw BarkVisorError.badRequest("unsupported compose feature: devices")
        }
        if service["build"] != nil {
            throw BarkVisorError.badRequest("unsupported compose feature: build")
        }
        if service["secrets"] != nil {
            throw BarkVisorError.badRequest("unsupported compose feature: secrets")
        }
        if service["image"] == nil {
            throw BarkVisorError.badRequest("compose service \(serviceName) must set image")
        }
        if let envFile = service["env_file"] {
            try validateEnvFile(envFile)
        }
        for key in service.keys {
            if key.hasPrefix("x-") { continue }
            if !allowedServiceKeys.contains(key),
               ![
                   "privileged", "network_mode", "pid", "cap_add", "devices", "build", "secrets",
               ].contains(key) {
                throw BarkVisorError.badRequest("unsupported compose feature: \(key)")
            }
        }
    }

    private static func validateEnvFile(_ value: Any) throws {
        let names: [String]
        if let text = stringValue(value) {
            names = [text]
        } else if let array = value as? [Any] {
            names = try array.map { item in
                guard let text = stringValue(item) else {
                    throw BarkVisorError.badRequest("unsupported compose feature: env_file")
                }
                return text
            }
        } else {
            throw BarkVisorError.badRequest("unsupported compose feature: env_file")
        }
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != ".env" {
                throw BarkVisorError.badRequest("unsupported compose feature: env_file")
            }
        }
    }

    private static func validateDependsOn(_ value: Any) throws {
        if value is [Any] { return }
        guard let mapping = asObject(value) else {
            throw BarkVisorError.badRequest("unsupported compose feature: depends_on")
        }
        for (_, raw) in mapping {
            if let condition = stringValue(asObject(raw)?["condition"]) {
                if condition != "service_started" {
                    throw BarkVisorError.badRequest("unsupported compose feature: depends_on")
                }
            }
        }
    }

    private struct VolumeRewrite {
        var mapping: [[String: Any]]
        var named: [String]
    }

    private static func rewriteVolumes(
        _ value: Any?,
        serviceName: String,
        volumeRoot: URL,
    ) throws -> VolumeRewrite {
        guard let value, !(value is NSNull) else {
            return VolumeRewrite(mapping: [], named: [])
        }
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else {
            throw BarkVisorError.badRequest("unsupported compose feature: volumes")
        }
        var mapping: [[String: Any]] = []
        var named: [String] = []
        for item in items {
            if let text = stringValue(item) {
                let parsed = try parseVolumeString(text, volumeRoot: volumeRoot)
                mapping.append(parsed.entry)
                if let name = parsed.named { named.append(name) }
                continue
            }
            guard let object = asObject(item) else {
                throw BarkVisorError.badRequest("unsupported compose feature: volumes")
            }
            let parsed = try parseVolumeObject(
                object,
                volumeRoot: volumeRoot,
                serviceName: serviceName,
            )
            mapping.append(parsed.entry)
            if let name = parsed.named { named.append(name) }
        }
        return VolumeRewrite(mapping: mapping, named: named)
    }

    private struct ParsedVolume {
        var entry: [String: Any]
        var named: String?
    }

    private static func parseVolumeString(
        _ text: String,
        volumeRoot: URL,
    ) throws -> ParsedVolume {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 {
            throw BarkVisorError.badRequest("unsupported compose feature: bind")
        }
        let source = parts[0]
        let target = parts[1]
        let mode = parts.count > 2 ? parts[2] : nil
        if source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~") {
            throw BarkVisorError.badRequest("unsupported compose feature: bind")
        }
        return try namedVolume(
            source: source,
            target: target,
            volumeRoot: volumeRoot,
            readOnly: mode?.contains("ro") == true,
        )
    }

    private static func parseVolumeObject(
        _ object: [String: Any],
        volumeRoot: URL,
        serviceName _: String,
    ) throws -> ParsedVolume {
        let type = stringValue(object["type"]) ?? "volume"
        let source = stringValue(object["source"]) ?? stringValue(object["source"])
        let target = stringValue(object["target"]) ?? stringValue(object["destination"])
        guard let target else {
            throw BarkVisorError.badRequest("unsupported compose feature: volumes")
        }
        if type == "bind" {
            throw BarkVisorError.badRequest("unsupported compose feature: bind")
        }
        if type == "volume" || type == "named" || source != nil {
            guard let source, !source.isEmpty else {
                throw BarkVisorError.badRequest("unsupported compose feature: volumes")
            }
            if source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~") {
                throw BarkVisorError.badRequest("unsupported compose feature: bind")
            }
            return try namedVolume(
                source: source,
                target: target,
                volumeRoot: volumeRoot,
                readOnly: boolValue(object["read_only"]),
            )
        }
        throw BarkVisorError.badRequest("unsupported compose feature: volumes")
    }

    private static func rewriteEnvironment(_ value: Any) throws -> [String: String] {
        var out: [String: String] = [:]
        if let object = asObject(value) {
            for (key, raw) in object {
                try ComposeRuntime.requireEnvKey(key)
                guard let text = stringValue(raw) else {
                    throw BarkVisorError.badRequest("unsupported compose feature: environment")
                }
                out[key] = text
            }
            return out
        }
        if let array = value as? [Any] {
            for item in array {
                guard let text = stringValue(item), let eq = text.firstIndex(of: "=") else {
                    throw BarkVisorError.badRequest("unsupported compose feature: environment")
                }
                let key = String(text[..<eq])
                try ComposeRuntime.requireEnvKey(key)
                out[key] = String(text[text.index(after: eq)...])
            }
            return out
        }
        throw BarkVisorError.badRequest("unsupported compose feature: environment")
    }

    private static func namedVolume(
        source: String,
        target: String,
        volumeRoot: URL,
        readOnly: Bool,
    ) throws -> ParsedVolume {
        try rejectNamedVolumeName(source)
        let dest = volumeRoot.appendingPathComponent(source, isDirectory: true)
        let path = try requirePath(under: volumeRoot, candidate: dest)
        var entry: [String: Any] = [
            "type": "bind",
            "source": path,
            "target": target,
        ]
        if readOnly { entry["read_only"] = true }
        return ParsedVolume(entry: entry, named: source)
    }

    private static func rejectNamedVolumeName(_ source: String) throws {
        if source == "." || source == ".." {
            throw BarkVisorError.badRequest("unsupported compose feature: bind")
        }
        let separators = CharacterSet(charactersIn: "/\\")
        if source.rangeOfCharacter(from: separators) != nil {
            throw BarkVisorError.badRequest("unsupported compose feature: bind")
        }
        guard let first = source.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first)
        else {
            throw BarkVisorError.badRequest("unsupported compose feature: volumes")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        if !source.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            throw BarkVisorError.badRequest("unsupported compose feature: volumes")
        }
    }

    private static func requirePath(under root: URL, candidate: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if !path.hasPrefix(prefix) {
            throw BarkVisorError.badRequest("unsupported compose feature: bind")
        }
        return path
    }

    private static func parsePorts(_ value: Any?) throws -> [PublishedPort] {
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
                let port = PublishedPort(hostPort: published, containerPort: target, proto: proto)
                result.append(
                    PublishedPort(
                        hostPort: port.hostPort,
                        containerPort: port.containerPort,
                        proto: port.proto,
                        url: port.openURL,
                    ),
                )
                continue
            }
            throw BarkVisorError.badRequest("unsupported compose feature: ports")
        }
        return result
    }

    private static func parsePortString(_ text: String) -> PublishedPort? {
        var raw = text
        var proto = "tcp"
        if let slash = raw.lastIndex(of: "/") {
            proto = String(raw[raw.index(after: slash)...]).lowercased()
            raw = String(raw[..<slash])
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
        let port = PublishedPort(hostPort: host, containerPort: container, proto: proto)
        return PublishedPort(
            hostPort: port.hostPort,
            containerPort: port.containerPort,
            proto: port.proto,
            url: port.openURL,
        )
    }

    private static func mergeLabels(_ existing: Any?, workloadID: String) -> [String: String] {
        var labels: [String: String] = [:]
        if let object = asObject(existing) {
            for (key, value) in object {
                if let text = stringValue(value) { labels[key] = text }
            }
        } else if let array = existing as? [Any] {
            for item in array {
                guard let text = stringValue(item), let eq = text.firstIndex(of: "=") else { continue }
                labels[String(text[..<eq])] = String(text[text.index(after: eq)...])
            }
        }
        labels[workloadLabelKey] = workloadID
        labels[kindLabelKey] = WorkloadSpec.kindApplication
        return labels
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

    private static func boolValue(_ value: Any?) -> Bool {
        isTruthy(value)
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return false }
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            let lower = string.lowercased()
            if lower == "false" || lower == "no" || lower == "0" || lower.isEmpty { return false }
            return true
        }
        if let int = value as? Int { return int != 0 }
        return true
    }

    private static func isEmptyValue(_ value: Any) -> Bool {
        if let array = value as? [Any] { return array.isEmpty }
        if let object = asObject(value) { return object.isEmpty }
        return false
    }
}
