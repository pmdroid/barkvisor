import Foundation

public enum LinuxServerAppCatalog {
    public static let source = AppCatalogEntryDTO.linuxServerSource
    public static let catalogName = "LinuxServer.io"
    public static let originURL = "barkvisor://builtin/linuxserver"

    public static func isOrigin(_ url: String) -> Bool {
        BuiltinAppCatalogRegistry.parseName(url) == "linuxserver"
    }

    public static func load() throws -> AppCatalogDocument {
        try load(files: manifestFiles())
    }

    public static func load(files: [String: Data]) throws -> AppCatalogDocument {
        var apps: [AppCatalogEntryDTO] = []
        for name in files.keys.sorted() {
            guard name.hasSuffix(".json"), let data = files[name] else { continue }
            let entry = try decodeEntry(data)
            try validate(entry)
            apps.append(entry)
        }
        if apps.isEmpty {
            throw BarkVisorError.repositorySyncFailed("LinuxServer catalog contained no apps")
        }
        return AppCatalogDocument(name: catalogName, source: source, apps: apps)
    }

    public static func encodedDocument() throws -> Data {
        try BigBearAppCatalog.encodeCatalog(load())
    }

    public static func decodeCatalog(_ data: Data) throws -> AppCatalogDocument {
        try BigBearAppCatalog.decodeCatalog(data)
    }

    static func manifestDirectory() -> URL? {
        if let bundled = Bundle.module.url(forResource: "linuxserver", withExtension: nil, subdirectory: "app-catalog")
            ?? Bundle.module.url(forResource: "linuxserver", withExtension: nil, subdirectory: "Resources/app-catalog")
            ?? Bundle.module.resourceURL?.appendingPathComponent("app-catalog/linuxserver", isDirectory: true) {
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        let here = URL(fileURLWithPath: #filePath)
        let checkout = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/app-catalog/linuxserver", isDirectory: true)
        if FileManager.default.fileExists(atPath: checkout.path) {
            return checkout
        }
        return nil
    }

    private static func manifestFiles() throws -> [String: Data] {
        guard let dir = manifestDirectory() else {
            throw BarkVisorError.repositorySyncFailed("LinuxServer catalog manifests are missing")
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
        )
        var files: [String: Data] = [:]
        for url in urls where url.pathExtension == "json" {
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return files
    }

    private static func decodeEntry(_ data: Data) throws -> AppCatalogEntryDTO {
        do {
            var entry = try JSONDecoder().decode(AppCatalogEntryDTO.self, from: data)
            if entry.source.isEmpty {
                entry.source = source
            }
            return entry
        } catch {
            throw BarkVisorError.repositorySyncFailed(
                "LinuxServer catalog JSON is invalid: \(error.localizedDescription)",
            )
        }
    }

    private static func validate(_ entry: AppCatalogEntryDTO) throws {
        if entry.source != source {
            throw BarkVisorError.repositorySyncFailed("LinuxServer app \(entry.id) has the wrong source")
        }
        let image = entry.image ?? ""
        if !image.hasPrefix("lscr.io/linuxserver/") {
            throw BarkVisorError.repositorySyncFailed("LinuxServer app \(entry.id) must use lscr.io")
        }
        let blob = entry.compose.lowercased()
        if blob.contains("/dev/dri") {
            throw BarkVisorError.repositorySyncFailed("LinuxServer app \(entry.id) maps /dev/dri")
        }
        if blob.contains("docker_mods") || entry.envSchema.contains(where: { $0.name == "DOCKER_MODS" }) {
            throw BarkVisorError.repositorySyncFailed("LinuxServer app \(entry.id) uses Docker Mods")
        }
        if entry.envSchema.contains(where: { $0.name.hasPrefix("FILE__") }) {
            throw BarkVisorError.repositorySyncFailed("LinuxServer app \(entry.id) uses FILE__ secrets")
        }
        if blob.contains("network_mode") {
            throw BarkVisorError.repositorySyncFailed("LinuxServer app \(entry.id) uses host network")
        }
        if blob.contains("privileged") {
            throw BarkVisorError.repositorySyncFailed("LinuxServer app \(entry.id) is privileged")
        }
        if blob.contains("\ndevices:") || blob.contains(" devices:") {
            throw BarkVisorError.repositorySyncFailed("LinuxServer app \(entry.id) maps devices")
        }
    }
}
