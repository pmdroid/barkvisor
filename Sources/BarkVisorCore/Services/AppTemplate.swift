import Foundation
import Yams

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

public struct AppTemplateRender: Equatable, Sendable {
    public var compose: String
    public var env: [String: String]
    public var sharedPaths: [String]
    public var secretKeys: [String]

    public init(
        compose: String,
        env: [String: String],
        sharedPaths: [String],
        secretKeys: [String],
    ) {
        self.compose = compose
        self.env = env
        self.sharedPaths = sharedPaths
        self.secretKeys = secretKeys
    }
}

public struct AppTemplateExtraFolder: Equatable, Sendable {
    public var hostPath: String
    public var containerPath: String

    public init(hostPath: String, containerPath: String) {
        self.hostPath = hostPath
        self.containerPath = containerPath
    }
}

public enum AppTemplate {
    public static let redacted = "***"
    public static let configContainer = "/config"

    private static let hiddenEnvNames: Set<String> = [
        "DOCKER_MODS",
        "WEBUI_PORT",
        "TORRENTING_PORT",
        "GITEA__server__SSH_PORT",
        "JELLYFIN_PublishedServerUrl",
        "PROXY_DOMAIN",
        "HASHED_PASSWORD",
        "SUDO_PASSWORD_HASH",
        "SUBFOLDER",
        "APP_URL",
        "GITEA__server__ROOT_URL",
        "GITEA__server__DOMAIN",
        "PAPERLESS_URL",
        "PAPERLESS_CSRF_TRUSTED_ORIGINS",
        "PHOTOPRISM_SITE_URL",
        "GF_SERVER_ROOT_URL",
        "GF_SERVER_SERVE_FROM_SUB_PATH",
        "BARKVISOR_BASE_PATH",
        "BARKVISOR_PUBLIC_URL",
        "TRUSTED_PROXIES",
        "OVERWRITEPROTOCOL",
        "OVERWRITEHOST",
        "OVERWRITEWEBROOT",
    ]
    private static let advancedEnvNames: Set<String> = ["UMASK"]
    private static let deviceEnvNames: Set<String> = ["PUID", "PGID", "TZ"]
    private static let placeholderSecrets: Set<String> = [
        "casaos", "password", "changeme", "secret", "admin",
    ]

    public static func fields(
        from entry: AppCatalogEntryDTO,
        puid: String? = nil,
        pgid: String? = nil,
        timezone: String? = nil,
    ) -> [AppTemplateField] {
        var out: [AppTemplateField] = []
        let skipEnv = hiddenEnvNames.union(portLockstepNames(entry)).union(Set(entry.ui.basePathEnv))
        let linked = linkedSecretGroups(entry.envSchema.map(\.name))
        var seenEnv: Set<String> = []
        for env in entry.envSchema {
            if skipEnv.contains(env.name) { continue }
            if BigBearAppCatalog.shouldHideEnv(env.name) { continue }
            if env.name.hasPrefix("FILE__") { continue }
            if seenEnv.contains(env.name) { continue }
            if let group = linked.first(where: { $0.contains(env.name) }) {
                for name in group {
                    seenEnv.insert(name)
                }
                let primary = group.contains("DB_PASSWORD") ? "DB_PASSWORD" : env.name
                let source = entry.envSchema.first { $0.name == primary } ?? env
                out.append(envField(source, linked: group, puid: puid, pgid: pgid, timezone: timezone))
                continue
            }
            seenEnv.insert(env.name)
            out.append(envField(env, linked: [env.name], puid: puid, pgid: pgid, timezone: timezone))
        }
        for volume in entry.volumes {
            if isAutoVolume(volume) { continue }
            out.append(pathField(volume, appId: entry.id))
        }
        for port in entry.ports {
            out.append(portField(port, ui: port.ui, scheme: entry.ui.scheme, path: entry.ui.path))
        }
        return out
    }

    public static func isAdvanced(_ field: AppTemplateField) -> Bool {
        if let name = field.envName, advancedEnvNames.contains(name) { return true }
        return false
    }

    public static func isSecretEnvName(_ name: String) -> Bool {
        BigBearAppCatalog.inferKind(name: name, defaultValue: nil) == "secret"
    }

    public static func generateSecret() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        let bytes = PlatformRandom.secureBytes(count: 24)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    public static func shouldGenerateSecret(defaultValue: String?) -> Bool {
        let raw = (defaultValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return true }
        let lower = raw.lowercased()
        if placeholderSecrets.contains(lower) { return true }
        if lower.contains("casaos") { return true }
        return false
    }

    public static func seedValues(
        _ fields: [AppTemplateField],
        existing: [String: String] = [:],
    ) -> [String: String] {
        var values: [String: String] = existing
        for field in fields {
            if let current = values[field.id], !current.isEmpty { continue }
            if field.kind == "secret" {
                if field.required || shouldGenerateSecret(defaultValue: field.defaultValue) {
                    if field.required || !(field.defaultValue ?? "").isEmpty {
                        values[field.id] = generateSecret()
                    }
                }
                continue
            }
            if let defaultValue = field.defaultValue, !defaultValue.isEmpty {
                values[field.id] = defaultValue
            }
        }
        return values
    }

    public static func missingRequired(
        _ fields: [AppTemplateField],
        values: [String: String],
    ) -> AppTemplateField? {
        fields.first { field in
            guard field.required else { return false }
            if isAdvanced(field) { return false }
            let value = values[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty
        }
    }

    public static func validate(
        _ fields: [AppTemplateField],
        values: [String: String],
    ) throws {
        if let field = missingRequired(fields, values: values) {
            throw BarkVisorError.badRequest("\(field.label) is required")
        }
    }

    public static func devicePrefill() -> (puid: String, pgid: String, timezone: String) {
        (puid: devicePUID(), pgid: devicePGID(), timezone: TimeZone.current.identifier)
    }

    public static func openURL(scheme: String, path: String, host: String, port: Int) -> String {
        var builtScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        if builtScheme.isEmpty { builtScheme = "http" }
        var builtPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if builtPath == "/" { builtPath = "" }
        if !builtPath.isEmpty, !builtPath.hasPrefix("/") {
            builtPath = "/" + builtPath
        }
        return "\(builtScheme)://\(host):\(port)\(builtPath)"
    }

    public static func render(
        entry: AppCatalogEntryDTO,
        values: [String: String],
        extraFolders: [AppTemplateExtraFolder] = [],
        lanBind: String? = nil,
        ingress: WorkloadIngress? = nil,
        workloadID: String? = nil,
        listenPort: Int = Config.port,
    ) throws -> AppTemplateRender {
        let fields = entry.fields ?? Self.fields(from: entry)
        var working = values
        if let hostPort = ingress?.hostPort, let ui = uiPortField(fields) {
            working[ui.id] = String(hostPort)
        }
        try validate(fields, values: working)
        var env: [String: String] = [:]
        var secretKeys: [String] = []
        var binds: [String: String] = [:]
        var shared: [String] = []
        var ports: [String: (host: Int, proto: String)] = [:]
        for field in fields {
            let raw = working[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let names = envNames(for: field, entry: entry) {
                if field.kind == "secret" {
                    secretKeys.append(contentsOf: names)
                    if raw.isEmpty || raw == redacted { continue }
                }
                if raw.isEmpty { continue }
                for name in names {
                    env[name] = raw
                }
            } else if let container = field.volumePath {
                if raw.isEmpty { continue }
                binds[container] = raw
                if !shared.contains(raw) { shared.append(raw) }
            } else if let spec = field.portSpec, let host = Int(raw) {
                ports[portKey(container: spec.container, proto: spec.proto)] = (
                    host: host, proto: spec.proto,
                )
            }
        }
        for extra in extraFolders {
            let host = extra.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let container = extra.containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty || container.isEmpty { continue }
            binds[container] = host
            if !shared.contains(host) { shared.append(host) }
        }
        applyPortLockstep(entry: entry, ports: ports, env: &env)
        applyPublishedServerURL(entry: entry, ports: ports, lanBind: lanBind, env: &env)
        if let extra = ingress?.extraBinds {
            for path in extra {
                let host = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if host.isEmpty { continue }
                if !shared.contains(host) { shared.append(host) }
            }
        }
        let lan = (lanBind ?? HostInfoService.lanBindIPv4())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = lan.isEmpty ? "127.0.0.1" : lan
        let id = (workloadID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? entry.id
        let managed = AppIngress.managedEnv(
            id: id,
            names: AppIngress.envNames(catalog: entry.ui, schema: entry.envSchema),
            catalogProxy: entry.ui.proxy,
            ingress: ingress,
            scheme: "http",
            host: host,
            listenPort: listenPort,
        )
        if let merged = AppIngress.mergeEnv(
            existing: env,
            extra: ingress?.extraEnv,
            managed: managed,
            enabled: AppIngress.isEnabled(ingress),
        ) {
            env = merged
        }
        let compose = try rewriteCompose(
            entry.compose,
            binds: binds,
            ports: ports,
            env: env,
            secretKeys: Set(secretKeys),
        )
        return AppTemplateRender(
            compose: compose,
            env: env,
            sharedPaths: shared,
            secretKeys: Array(Set(secretKeys)).sorted(),
        )
    }

    public static func applicationDocument(
        entry: AppCatalogEntryDTO,
        name: String,
        values: [String: String],
        extraFolders: [AppTemplateExtraFolder] = [],
        gpuShare: [WorkloadGPUShare] = [],
        ingress: WorkloadIngress? = nil,
    ) throws -> [String: Any] {
        let rendered = try render(
            entry: entry, values: values, extraFolders: extraFolders, ingress: ingress,
        )
        var spec: [String: Any] = [
            "runtime": WorkloadSpec.runtimeDevice,
            "compose": rendered.compose,
        ]
        if !rendered.env.isEmpty {
            spec["env"] = rendered.env
        }
        if !rendered.sharedPaths.isEmpty {
            spec["sharedPaths"] = rendered.sharedPaths
        }
        if !gpuShare.isEmpty {
            spec["gpuShare"] = gpuShare.map { ["id": $0.id] }
        }
        if let ingress {
            spec["ingress"] = ingressPayload(ingress)
        }
        return [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindApplication,
            "metadata": [
                "name": name,
                "labels": [
                    "catalog": entry.id,
                    "catalog-source": entry.source,
                ],
            ],
            "spec": spec,
        ]
    }

    public static func redact(_ spec: WorkloadSpec) -> WorkloadSpec {
        var copy = spec
        copy.spec.env = redactEnv(spec.spec.env)
        return copy
    }

    public static func redact(_ result: WorkloadApplyResult) -> WorkloadApplyResult {
        guard let diff = result.diff else { return result }
        return WorkloadApplyResult(
            op: result.op,
            id: result.id,
            generation: result.generation,
            diff: WorkloadApplyDiff(
                before: diff.before.map(redact),
                after: redact(diff.after),
            ),
        )
    }

    public static func redactEnv(_ env: [String: String]?) -> [String: String]? {
        guard let env else { return nil }
        var out: [String: String] = [:]
        for (key, value) in env {
            if isSecretEnvName(key), value != redacted {
                out[key] = redacted
            } else {
                out[key] = value
            }
        }
        return out
    }

    public static func mergeEnv(
        existing: [String: String]?,
        incoming: [String: String]?,
        disk: [String: String]? = nil,
    ) -> [String: String]? {
        var out = existing ?? [:]
        if let disk {
            for (key, value) in disk where out[key] == nil {
                out[key] = value
            }
        }
        guard let incoming else { return out.isEmpty ? nil : out }
        for (key, value) in incoming {
            if isSecretEnvName(key), value.isEmpty || value == redacted {
                continue
            }
            out[key] = value
        }
        return out.isEmpty ? nil : out
    }

    public static func isAutoVolume(_ volume: AppCatalogVolume) -> Bool {
        if volume.kind == "folder" { return false }
        return true
    }

    public static func isConfigVolume(_ volume: AppCatalogVolume) -> Bool {
        if volume.containerPath == configContainer { return true }
        if volume.containerPath.hasSuffix("/config") { return true }
        if let name = volume.name?.lowercased(), name.contains("config") { return true }
        return false
    }

    private static func envField(
        _ env: AppCatalogEnvVar,
        linked: [String],
        puid: String?,
        pgid: String?,
        timezone: String?,
    ) -> AppTemplateField {
        var defaultValue = env.defaultValue
        if env.kind == "secret", shouldGenerateSecret(defaultValue: defaultValue) {
            defaultValue = nil
        }
        if env.name == "PUID", let puid {
            defaultValue = puid
        } else if env.name == "PGID", let pgid {
            defaultValue = pgid
        } else if env.name == "TZ", let timezone {
            defaultValue = timezone
        } else if deviceEnvNames.contains(env.name), defaultValue == nil {
            let prefill = devicePrefill()
            if env.name == "PUID" { defaultValue = prefill.puid }
            if env.name == "PGID" { defaultValue = prefill.pgid }
            if env.name == "TZ" { defaultValue = prefill.timezone }
        }
        let kind = env.kind == "text" ? inferredSelectOrNumber(env) : env.kind
        let options = env.options ?? defaultOptions(name: env.name, kind: kind)
        let required = env.required && env.name != "UMASK" && env.name != "PLEX_CLAIM"
        return AppTemplateField(
            id: linked.contains("DB_PASSWORD") ? "database-password" : env.name.lowercased(),
            label: envLabel(env.name, linked: linked),
            description: env.description,
            kind: kind,
            required: required || (kind == "secret" && env.required),
            defaultValue: defaultValue,
            target: "env:\(env.name)",
            placeholder: kind == "secret" ? "Generate or paste" : nil,
            options: options,
        )
    }

    private static func pathField(_ volume: AppCatalogVolume, appId: String) -> AppTemplateField {
        let required = pathRequired(appId: appId, container: volume.containerPath)
        let leaf = volume.containerPath.split(separator: "/").last.map(String.init) ?? volume.containerPath
        return AppTemplateField(
            id: "path-\(leaf.lowercased())",
            label: volume.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? pathLabel(leaf),
            description: "Maps to \(volume.containerPath)",
            kind: "path",
            required: required,
            defaultValue: nil,
            target: "volume:\(volume.containerPath)",
            placeholder: "Choose a folder on this Device",
            options: nil,
        )
    }

    private static func portField(
        _ port: AppCatalogPort,
        ui: Bool,
        scheme: String,
        path: String,
    ) -> AppTemplateField {
        let container = port.container ?? port.host ?? 0
        let proto = port.proto.lowercased()
        let host = port.host ?? container
        let label: String = if ui {
            "Open UI"
        } else if proto == "udp" {
            "Port \(container)/udp"
        } else {
            port.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Port \(container)"
        }
        var description = port.description
        if ui {
            let extra = [scheme, path].filter { !$0.isEmpty }.joined(separator: " ")
            if description == nil, !extra.isEmpty {
                description = extra
            }
        }
        return AppTemplateField(
            id: "port-\(container)-\(proto)",
            label: label,
            description: description,
            kind: "port",
            required: ui,
            defaultValue: String(host),
            target: "port:\(container)/\(proto)",
            placeholder: nil,
            options: nil,
        )
    }

    private static func pathRequired(appId: String, container: String) -> Bool {
        let path = container.lowercased()
        let id = appId.lowercased()
        if id == "plex" {
            return path.contains("movie") || path == "/tv" || path.contains("/tv")
        }
        if path.contains("download") { return false }
        if id == "jellyfin" { return false }
        if id.contains("sonarr") || id.contains("radarr") || id.contains("lidarr"),
           path == "/tv" || path.contains("/tv") || path.contains("movie") {
            return false
        }
        return true
    }

    private static func pathLabel(_ leaf: String) -> String {
        let lower = leaf.lowercased()
        if lower == "tv" || lower == "tvshows" { return "TV" }
        if lower == "movies" { return "Movies" }
        if lower == "upload" { return "Library upload" }
        return leaf.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func envLabel(_ name: String, linked: [String]) -> String {
        if linked.contains("DB_PASSWORD") || linked.contains("POSTGRES_PASSWORD") {
            return "Database password"
        }
        switch name {
        case "PUID": return "PUID"
        case "PGID": return "PGID"
        case "TZ": return "TZ"
        case "UMASK": return "UMASK"
        case "PLEX_CLAIM": return "Plex claim"
        default:
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func inferredSelectOrNumber(_ env: AppCatalogEnvVar) -> String {
        if let options = env.options, !options.isEmpty { return "select" }
        if env.name == "VERSION" || env.name.contains("LOG_LEVEL") { return "select" }
        if let defaultValue = env.defaultValue, Int(defaultValue) != nil, !env.name.contains("PORT") {
            return "number"
        }
        return env.kind
    }

    private static func defaultOptions(name: String, kind: String) -> [String]? {
        guard kind == "select" else { return nil }
        if name == "VERSION" { return ["docker", "latest", "public"] }
        if name.contains("LOG_LEVEL") { return ["debug", "info", "warn", "error"] }
        return nil
    }

    private static func linkedSecretGroups(_ names: [String]) -> [[String]] {
        var groups: [[String]] = []
        if names.contains("DB_PASSWORD"), names.contains("POSTGRES_PASSWORD") {
            groups.append(["DB_PASSWORD", "POSTGRES_PASSWORD"])
        }
        return groups
    }

    private static func envNames(for field: AppTemplateField, entry: AppCatalogEntryDTO) -> [String]? {
        guard let name = field.envName else { return nil }
        let linked = linkedSecretGroups(entry.envSchema.map(\.name))
        if let group = linked.first(where: { $0.contains(name) }) {
            return group
        }
        return [name]
    }

    private static func portLockstepNames(_ entry: AppCatalogEntryDTO) -> Set<String> {
        var names: Set<String> = []
        for env in entry.envSchema {
            if env.name == "WEBUI_PORT" || env.name == "TORRENTING_PORT"
                || env.name == "GITEA__server__SSH_PORT" {
                names.insert(env.name)
            }
        }
        return names
    }

    private static func applyPortLockstep(
        entry: AppCatalogEntryDTO,
        ports: [String: (host: Int, proto: String)],
        env: inout [String: String],
    ) {
        let names = Set(entry.envSchema.map(\.name))
        if names.contains("WEBUI_PORT"), let ui = uiPort(entry, ports: ports) {
            env["WEBUI_PORT"] = String(ui)
        }
        if names.contains("TORRENTING_PORT") {
            if let torrent = ports[portKey(container: 6_881, proto: "tcp")]
                ?? ports[portKey(container: 6_881, proto: "udp")] {
                env["TORRENTING_PORT"] = String(torrent.host)
            }
        }
        if names.contains("GITEA__server__SSH_PORT") {
            if let ssh = ports[portKey(container: 22, proto: "tcp")]
                ?? ports[portKey(container: 2_222, proto: "tcp")] {
                env["GITEA__server__SSH_PORT"] = String(ssh.host)
            }
        }
    }

    private static func applyPublishedServerURL(
        entry: AppCatalogEntryDTO,
        ports: [String: (host: Int, proto: String)],
        lanBind: String?,
        env: inout [String: String],
    ) {
        let names = Set(entry.envSchema.map(\.name))
        guard names.contains("JELLYFIN_PublishedServerUrl") else { return }
        let lan = (lanBind ?? HostInfoService.lanBindIPv4())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !lan.isEmpty, let ui = uiPort(entry, ports: ports) else { return }
        let scheme = entry.ui.scheme.isEmpty ? "http" : entry.ui.scheme
        env["JELLYFIN_PublishedServerUrl"] = "\(scheme)://\(lan):\(ui)"
    }

    private static func uiPortField(_ fields: [AppTemplateField]) -> AppTemplateField? {
        fields.first { field in
            field.kind == "port" && field.label == "Open UI"
        } ?? fields.first { field in
            field.kind == "port" && (field.portSpec?.proto == "tcp")
        }
    }

    private static func ingressPayload(_ ingress: WorkloadIngress) -> [String: Any] {
        var payload: [String: Any] = ["enabled": ingress.enabled]
        if let mode = ingress.mode { payload["mode"] = mode }
        if let extraEnv = ingress.extraEnv { payload["extraEnv"] = extraEnv }
        if let hostPort = ingress.hostPort { payload["hostPort"] = hostPort }
        if let extraBinds = ingress.extraBinds { payload["extraBinds"] = extraBinds }
        return payload
    }

    private static func uiPort(
        _ entry: AppCatalogEntryDTO,
        ports: [String: (host: Int, proto: String)],
    ) -> Int? {
        if let ui = entry.ports.first(where: { $0.ui }), let container = ui.container {
            return ports[portKey(container: container, proto: ui.proto)]?.host
        }
        if let first = entry.ports.first(where: { $0.proto.lowercased() == "tcp" }),
           let container = first.container {
            return ports[portKey(container: container, proto: "tcp")]?.host
        }
        return nil
    }

    private static func portKey(container: Int, proto: String) -> String {
        "\(container)/\(proto.lowercased())"
    }

    private static func rewriteCompose(
        _ yaml: String,
        binds: [String: String],
        ports: [String: (host: Int, proto: String)],
        env: [String: String],
        secretKeys: Set<String>,
    ) throws -> String {
        let loaded: Any
        do {
            loaded = try Yams.load(yaml: yaml) ?? [String: Any]()
        } catch {
            throw BarkVisorError.badRequest("spec.compose is not valid YAML")
        }
        guard var root = asObject(loaded), var services = asObject(root["services"]) else {
            throw BarkVisorError.badRequest("spec.compose must declare services")
        }
        var remainingBinds = binds
        for name in services.keys.sorted() {
            guard var service = asObject(services[name]) else { continue }
            service["volumes"] = rewriteServiceVolumes(service["volumes"], binds: &remainingBinds)
            service["ports"] = rewriteServicePorts(service["ports"], ports: ports)
            if let environment = service["environment"] {
                service["environment"] = rewriteServiceEnvironment(
                    environment, env: env, secretKeys: secretKeys,
                )
            }
            if !env.isEmpty {
                service["env_file"] = ".env"
            }
            services[name] = service
        }
        if !remainingBinds.isEmpty, let first = services.keys.sorted().first,
           var service = asObject(services[first]) {
            var volumes = volumeArray(service["volumes"])
            for (container, host) in remainingBinds.sorted(by: { $0.key < $1.key }) {
                volumes.append([
                    "type": "bind",
                    "source": host,
                    "target": container,
                ])
            }
            service["volumes"] = volumes
            services[first] = service
        }
        root["services"] = services
        do {
            return try Yams.dump(object: root, width: -1)
        } catch {
            throw BarkVisorError.badRequest("spec.compose could not be rewritten")
        }
    }

    private static func rewriteServiceVolumes(_ value: Any?, binds: inout [String: String]) -> Any? {
        guard let value else { return value }
        var items = volumeArray(value)
        for i in items.indices {
            var item = items[i]
            let target = stringValue(item["target"]) ?? stringValue(item["destination"])
            guard let target else { continue }
            if let host = binds.removeValue(forKey: target) {
                item["type"] = "bind"
                item["source"] = host
                item["target"] = target
                item.removeValue(forKey: "destination")
                items[i] = item
            }
        }
        return items
    }

    private static func volumeArray(_ value: Any?) -> [[String: Any]] {
        guard let value else { return [] }
        if let array = value as? [Any] {
            return array.compactMap { item in
                if let object = asObject(item) { return object }
                if let text = stringValue(item) {
                    let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(
                        String.init,
                    )
                    if parts.count >= 2 {
                        return [
                            "type": parts[0].hasPrefix("/") ? "bind" : "volume",
                            "source": parts[0],
                            "target": parts[1],
                        ]
                    }
                }
                return nil
            }
        }
        return []
    }

    private static func rewriteServicePorts(_ value: Any?, ports: [String: (host: Int, proto: String)]) -> Any? {
        guard let value else { return value }
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else {
            return value
        }
        var out: [Any] = []
        for item in items {
            if let text = stringValue(item), let parsed = parsePortString(text) {
                let key = portKey(container: parsed.container, proto: parsed.proto)
                if let replacement = ports[key] {
                    var line = "\(replacement.host):\(parsed.container)"
                    if parsed.proto != "tcp" { line += "/\(parsed.proto)" }
                    out.append(line)
                } else {
                    out.append(text)
                }
                continue
            }
            if var object = asObject(item) {
                let target = intValue(object["target"]) ?? intValue(object["container_port"])
                let proto = (stringValue(object["protocol"]) ?? "tcp").lowercased()
                if let target, let replacement = ports[portKey(container: target, proto: proto)] {
                    object["published"] = replacement.host
                    object["protocol"] = proto
                }
                out.append(object)
                continue
            }
            out.append(item)
        }
        return out
    }

    private static func rewriteServiceEnvironment(
        _ value: Any,
        env: [String: String],
        secretKeys: Set<String>,
    ) -> [String: String] {
        var out: [String: String] = [:]
        if let object = asObject(value) {
            for (key, raw) in object {
                if secretKeys.contains(key) { continue }
                if let text = stringValue(raw) { out[key] = env[key] ?? text }
            }
        } else if let array = value as? [Any] {
            for item in array {
                guard let text = stringValue(item), let eq = text.firstIndex(of: "=") else { continue }
                let key = String(text[..<eq])
                if secretKeys.contains(key) { continue }
                out[key] = env[key] ?? String(text[text.index(after: eq)...])
            }
        }
        for (key, value) in env where !secretKeys.contains(key) {
            out[key] = value
        }
        return out
    }

    private static func parsePortString(_ text: String) -> (container: Int, host: Int, proto: String)? {
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
        guard let container, let host else { return nil }
        return (container, host, proto)
    }

    private static func devicePUID() -> String {
        #if os(Windows)
            "1000"
        #else
            String(getuid())
        #endif
    }

    private static func devicePGID() -> String {
        #if os(Windows)
            "1000"
        #else
            String(getgid())
        #endif
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

extension String {
    fileprivate var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
