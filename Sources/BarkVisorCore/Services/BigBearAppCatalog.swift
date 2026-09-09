import Foundation
import Yams

public enum BigBearAppCatalog {
    public static let source = AppCatalogEntryDTO.bigBearSource
    public static let catalogName = "Big Bear Universal Apps"
    public static let githubRepoURL = "https://github.com/bigbeartechworld/big-bear-universal-apps"
    public static let zipballURL =
        "https://codeload.github.com/bigbeartechworld/big-bear-universal-apps/zip/refs/heads/main"

    private static let hiddenEnvNames: Set<String> = [
        "DB_HOSTNAME", "POSTGRES_HOST", "PAPERLESS_REDIS", "COMPOSE_PROJECT_NAME",
        "REDIS_HOSTNAME",
    ]
    private static let mediaTokens = [
        "movies", "tv", "music", "photos", "pictures", "media", "download",
        "audiobook", "podcast", "spoken", "books",
    ]
    private static let allowedTopLevel: Set<String> = [
        "services", "volumes", "name", "version",
    ]
    private static let allowedServiceKeys: Set<String> = [
        "image", "ports", "environment", "env_file", "volumes", "restart", "user",
        "depends_on", "healthcheck", "command", "container_name", "labels",
        "entrypoint", "working_dir", "hostname", "expose", "pull_policy",
    ]
    private static let plexSlugs: Set<String> = ["plex"]

    public static func parse(files: [String: Data]) throws -> AppCatalogDocument {
        var grouped: [String: [String: Data]] = [:]
        for (path, bytes) in files {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.first == "apps", parts.count >= 3 else { continue }
            let slug = parts[1]
            if slug.hasPrefix("_") { continue }
            if parts.contains("converted") { continue }
            let rest = parts.dropFirst(2).joined(separator: "/")
            grouped[slug, default: [:]][rest] = bytes
        }
        var apps: [AppCatalogEntryDTO] = []
        for slug in grouped.keys.sorted() {
            guard let files = grouped[slug] else { continue }
            if let entry = parseApp(slug: slug, files: files) {
                apps.append(entry)
            }
        }
        return AppCatalogDocument(name: catalogName, source: source, apps: apps)
    }

    public static func parseZip(_ data: Data) throws -> AppCatalogDocument {
        try parse(files: CatalogZip.appFiles(from: data))
    }

    public static func decodeCatalog(_ data: Data) throws -> AppCatalogDocument {
        if looksLikeJSON(data) {
            do {
                return try JSONDecoder().decode(AppCatalogDocument.self, from: data)
            } catch {
                throw BarkVisorError.repositorySyncFailed(
                    "App catalog JSON is invalid: \(error.localizedDescription)",
                )
            }
        }
        if looksLikeZip(data) {
            return try parseZip(data)
        }
        throw BarkVisorError.repositorySyncFailed("App catalog must be JSON or a zip of apps/")
    }

    public static func encodeCatalog(_ document: AppCatalogDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    public static func zipballURL(from repoURL: String) -> URL? {
        let trimmed = repoURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        if host == "codeload.github.com" { return url }
        guard host == "github.com" else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.last == "archive" || parts.last?.hasSuffix(".zip") == true {
            return URL(string: trimmed)
        }
        if parts.last?.hasSuffix(".git") == true {
            parts[parts.count - 1] = String(parts[parts.count - 1].dropLast(4))
        }
        guard parts.count >= 2 else { return nil }
        let org = parts[0]
        let repo = parts[1]
        return URL(string: "https://codeload.github.com/\(org)/\(repo)/zip/refs/heads/main")
    }

    public static func isGitHubAppsRepo(_ url: String) -> Bool {
        zipballURL(from: url) != nil
    }

    private static func parseApp(slug: String, files: [String: Data]) -> AppCatalogEntryDTO? {
        guard let appJSON = files["app.json"],
              let meta = try? JSONSerialization.jsonObject(with: appJSON) as? [String: Any]
        else { return nil }
        let technical = asObject(meta["technical"]) ?? [:]
        let composeName = stringValue(technical["compose_file"]) ?? "docker-compose.yml"
        guard let composeData = files[composeName] ?? files["docker-compose.yml"],
              let composeText = String(data: composeData, encoding: .utf8)
        else { return nil }
        let metadata = asObject(meta["metadata"]) ?? [:]
        let visual = asObject(meta["visual"]) ?? [:]
        let deployment = asObject(meta["deployment"]) ?? [:]
        let uiObject = asObject(meta["ui"]) ?? [:]
        let id = stringValue(metadata["id"]) ?? slug
        let name = stringValue(metadata["name"]) ?? slug
        let rewritePlex = plexSlugs.contains(id) || plexSlugs.contains(slug)
        let inspected = inspectCompose(composeText, rewritePlexHost: rewritePlex)
        let arches = stringArray(technical["architectures"]).map {
            PlatformCapabilities.normalizedArch($0)
        }
        let envSchema = envVars(from: deployment["environment_variables"])
        let volumes = volumesFromCompose(inspected.volumeMounts, appJSON: deployment["volumes"])
        let ui = AppCatalogUI(
            scheme: stringValue(uiObject["scheme"]) ?? "http",
            path: stringValue(uiObject["path"]) ?? "",
            tips: stringMap(uiObject["tips"]),
            proxy: "direct",
            basePathEnv: [],
        )
        return AppCatalogEntryDTO(
            id: id,
            name: name,
            tagline: stringValue(metadata["tagline"]),
            description: stringValue(metadata["description"]),
            iconUrl: stringValue(visual["icon"]) ?? stringValue(visual["logo"]),
            category: stringValue(metadata["category"]) ?? "Apps",
            arches: arches,
            source: stringValue(metadata["source"]) ?? source,
            compose: inspected.yaml,
            envSchema: envSchema,
            volumes: volumes,
            ports: inspected.ports,
            image: inspected.image,
            digest: inspected.digest,
            unsupportedReasons: inspected.reasons,
            ui: ui,
        )
    }

    private struct InspectedCompose {
        var yaml: String
        var reasons: [String]
        var ports: [AppCatalogPort]
        var volumeMounts: [AppCatalogVolume]
        var image: String?
        var digest: String?
    }

    private static func inspectCompose(_ yaml: String, rewritePlexHost: Bool) -> InspectedCompose {
        let loaded: Any
        do {
            loaded = try Yams.load(yaml: yaml) ?? [String: Any]()
        } catch {
            return InspectedCompose(
                yaml: yaml,
                reasons: ["compose yaml"],
                ports: [],
                volumeMounts: [],
                image: nil,
                digest: nil,
            )
        }
        guard var root = asObject(loaded) else {
            return InspectedCompose(
                yaml: yaml, reasons: ["compose yaml"], ports: [], volumeMounts: [], image: nil,
                digest: nil,
            )
        }
        var reasons: [String] = []
        if containsInterpolation(root) {
            reasons.append("interpolation")
        }
        for key in root.keys {
            if key.hasPrefix("x-") { continue }
            if key == "secrets" || key == "configs" {
                reasons.append(key)
            } else if key == "networks" {
                reasons.append("networks")
            } else if !allowedTopLevel.contains(key) {
                reasons.append(key)
            }
        }
        if root["build"] != nil { reasons.append("build") }
        guard var services = asObject(root["services"]), !services.isEmpty else {
            reasons.append("services")
            return InspectedCompose(
                yaml: yaml, reasons: unique(reasons), ports: [], volumeMounts: [], image: nil,
                digest: nil,
            )
        }
        var ports: [AppCatalogPort] = []
        var mounts: [AppCatalogVolume] = []
        var firstImage: String?
        var firstDigest: String?
        var named: [String] = []
        for name in services.keys.sorted() {
            guard var service = asObject(services[name]) else {
                reasons.append("services.\(name)")
                continue
            }
            if rewritePlexHost, stringValue(service["network_mode"])?.lowercased() == "host" {
                service.removeValue(forKey: "network_mode")
                if service["ports"] == nil {
                    service["ports"] = ["32400:32400"]
                }
            }
            reasons.append(contentsOf: serviceReasons(service, serviceName: name))
            if let image = stringValue(service["image"]), firstImage == nil {
                let parsed = splitImage(image)
                firstImage = parsed.reference
                firstDigest = parsed.digest
            }
            ports.append(contentsOf: parsePorts(service["ports"]))
            let volumeResult = parseVolumes(service["volumes"])
            mounts.append(contentsOf: volumeResult.mounts)
            named.append(contentsOf: volumeResult.named)
            var cleaned: [String: Any] = [:]
            for key in allowedServiceKeys {
                if let value = service[key] { cleaned[key] = value }
            }
            if cleaned["image"] == nil, let image = service["image"] {
                cleaned["image"] = image
            }
            services[name] = cleaned
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
        let dumped = (try? Yams.dump(object: root, width: -1)) ?? yaml
        return InspectedCompose(
            yaml: dumped,
            reasons: unique(reasons),
            ports: ports,
            volumeMounts: mounts,
            image: firstImage,
            digest: firstDigest,
        )
    }

    private static func serviceReasons(_ service: [String: Any], serviceName _: String) -> [String] {
        var reasons: [String] = []
        if isTruthy(service["privileged"]) { reasons.append("privileged") }
        if let mode = stringValue(service["network_mode"])?.lowercased() {
            if mode == "host" {
                reasons.append("host network")
            } else if mode != "bridge" {
                reasons.append("network_mode")
            }
        }
        if let pid = stringValue(service["pid"])?.lowercased(), pid == "host" {
            reasons.append("pid host")
        } else if service["pid"] != nil {
            reasons.append("pid")
        }
        if let caps = service["cap_add"], !isEmptyValue(caps) {
            reasons.append("cap_add")
        }
        if let devices = service["devices"], !isEmptyValue(devices) {
            reasons.append("devices")
        }
        if service["build"] != nil { reasons.append("build") }
        if service["secrets"] != nil { reasons.append("secrets") }
        if service["image"] == nil { reasons.append("image") }
        if mentionsDockerSock(service["volumes"]) {
            reasons.append("docker.sock")
        }
        for key in service.keys {
            if key.hasPrefix("x-") { continue }
            if allowedServiceKeys.contains(key) { continue }
            if [
                "privileged", "network_mode", "pid", "cap_add", "devices", "build", "secrets",
            ].contains(key) { continue }
            reasons.append(key)
        }
        return reasons
    }

    private static func mentionsDockerSock(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let text = stringValue(value) {
            return text.contains("docker.sock")
        }
        if let array = value as? [Any] {
            return array.contains { mentionsDockerSock($0) }
        }
        if let object = asObject(value) {
            return object.values.contains { mentionsDockerSock($0) }
        }
        return false
    }

    private struct VolumeParse {
        var mounts: [AppCatalogVolume]
        var named: [String]
    }

    private static func parseVolumes(_ value: Any?) -> VolumeParse {
        guard let value, !(value is NSNull) else {
            return VolumeParse(mounts: [], named: [])
        }
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else {
            return VolumeParse(mounts: [], named: [])
        }
        var mounts: [AppCatalogVolume] = []
        var named: [String] = []
        for item in items {
            if let text = stringValue(item) {
                let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 2 {
                    let source = parts[0]
                    let target = parts[1]
                    if source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~") {
                        continue
                    }
                    named.append(source)
                    mounts.append(
                        AppCatalogVolume(
                            containerPath: target,
                            name: source,
                            kind: isMediaVolume(source) ? "folder" : "volume",
                        ),
                    )
                }
                continue
            }
            if let object = asObject(item) {
                let source = stringValue(object["source"])
                let target = stringValue(object["target"]) ?? stringValue(object["destination"])
                guard let target else { continue }
                if let source, !source.hasPrefix("/"), !source.hasPrefix("."), !source.hasPrefix("~") {
                    named.append(source)
                    mounts.append(
                        AppCatalogVolume(
                            containerPath: target,
                            name: source,
                            kind: isMediaVolume(source) ? "folder" : "volume",
                        ),
                    )
                }
            }
        }
        return VolumeParse(mounts: mounts, named: named)
    }

    private static func volumesFromCompose(
        _ mounts: [AppCatalogVolume],
        appJSON: Any?,
    ) -> [AppCatalogVolume] {
        var descriptions: [String: String] = [:]
        if let array = appJSON as? [Any] {
            for item in array {
                guard let object = asObject(item) else { continue }
                let container = stringValue(object["container"]) ?? ""
                if let description = stringValue(object["description"]) {
                    descriptions[container] = description
                    if let name = mounts.first(where: { $0.name == container })?.name {
                        descriptions[name] = description
                    }
                }
            }
        }
        return mounts.map { mount in
            var copy = mount
            if let name = mount.name, let description = descriptions[name] {
                copy.description = description
            } else if let description = descriptions[mount.containerPath] {
                copy.description = description
            }
            return copy
        }
    }

    private static func isMediaVolume(_ name: String) -> Bool {
        let lower = name.lowercased()
        return mediaTokens.contains { lower.contains($0) }
    }

    private static func parsePorts(_ value: Any?) -> [AppCatalogPort] {
        guard let value, !(value is NSNull) else { return [] }
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else {
            return []
        }
        var result: [AppCatalogPort] = []
        for item in items {
            if let text = stringValue(item), let port = parsePortString(text) {
                result.append(port)
                continue
            }
            if let object = asObject(item) {
                let published = intValue(object["published"]) ?? intValue(object["host_port"])
                let target = intValue(object["target"]) ?? intValue(object["container_port"])
                let proto = (stringValue(object["protocol"]) ?? "tcp").lowercased()
                result.append(
                    AppCatalogPort(
                        container: target,
                        host: published,
                        proto: proto,
                        ui: false,
                    ),
                )
            }
        }
        return result
    }

    private static func parsePortString(_ text: String) -> AppCatalogPort? {
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
        guard let container else { return nil }
        return AppCatalogPort(container: container, host: host, proto: proto, ui: false)
    }

    private static func envVars(from raw: Any?) -> [AppCatalogEnvVar] {
        guard let array = raw as? [Any] else { return [] }
        var out: [AppCatalogEnvVar] = []
        for item in array {
            guard let object = asObject(item), let name = stringValue(object["name"]) else { continue }
            if shouldHideEnv(name) { continue }
            let defaultValue = stringValue(object["default"])
            out.append(
                AppCatalogEnvVar(
                    name: name,
                    defaultValue: defaultValue,
                    required: boolValue(object["required"]),
                    description: stringValue(object["description"]),
                    kind: inferKind(name: name, defaultValue: defaultValue),
                ),
            )
        }
        return out
    }

    static func shouldHideEnv(_ name: String) -> Bool {
        if hiddenEnvNames.contains(name) { return true }
        if name.hasSuffix("_HOSTNAME") { return true }
        if name.hasSuffix("_HOST") { return true }
        return false
    }

    static func inferKind(name: String, defaultValue: String?) -> String {
        let upper = name.uppercased()
        if upper.contains("PASSWORD") || upper.contains("SECRET") || upper.contains("TOKEN")
            || upper.contains("CLAIM") || (upper.contains("_KEY") && !upper.contains("PUBKEY")) {
            return "secret"
        }
        let lowered = (defaultValue ?? "").lowercased()
        if lowered == "true" || lowered == "false" || upper.hasPrefix("ENABLE_")
            || upper.hasPrefix("DISABLE_") {
            return "bool"
        }
        return "text"
    }

    private static func splitImage(_ image: String) -> (reference: String, digest: String?) {
        if let range = image.range(of: "@sha256:") {
            let digest = String(image[range.lowerBound...].dropFirst(1))
            let reference = String(image[..<range.lowerBound])
            return (reference, digest)
        }
        return (image, nil)
    }

    private static func containsInterpolation(_ value: Any) -> Bool {
        if let text = value as? String, text.contains("$") { return true }
        if let array = value as? [Any] {
            return array.contains { containsInterpolation($0) }
        }
        if let object = asObject(value) {
            return object.contains { key, nested in
                key.contains("$") || containsInterpolation(nested)
            }
        }
        return false
    }

    private static func unique(_ reasons: [String]) -> [String] {
        var seen: [String] = []
        for reason in reasons where !seen.contains(reason) {
            seen.append(reason)
        }
        return seen
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        var i = 0
        let bytes = [UInt8](data.prefix(64))
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D
            || bytes[i] == 0x09 {
            i += 1
        }
        return i < bytes.count && (bytes[i] == 0x7B || bytes[i] == 0x5B)
    }

    private static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B
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
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            let lower = string.lowercased()
            return lower == "true" || lower == "yes" || lower == "1"
        }
        if let int = value as? Int { return int != 0 }
        return false
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

    private static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { stringValue($0) }
        }
        if let string = stringValue(value) { return [string] }
        return []
    }

    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let object = asObject(value) else { return [:] }
        var out: [String: String] = [:]
        for (key, nested) in object {
            if let text = stringValue(nested) { out[key] = text }
        }
        return out
    }
}
