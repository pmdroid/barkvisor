import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct LinuxServerAppCatalogTests {
    @Test func `bundled catalog is linuxserver lscr images without dri`() throws {
        let catalog = try LinuxServerAppCatalog.load()
        #expect(catalog.source == AppCatalogEntryDTO.linuxServerSource)
        #expect(catalog.name == LinuxServerAppCatalog.catalogName)
        #expect(catalog.apps.count >= 11)
        let ids = Set(catalog.apps.map(\.id))
        for slug in [
            "jellyfin", "plex", "sonarr", "radarr", "prowlarr", "qbittorrent", "nginx",
            "nextcloud", "homeassistant", "freshrss", "code-server",
        ] {
            #expect(ids.contains(slug))
        }
        #expect(!ids.contains("grafana"))
        #expect(!ids.contains("whoami"))
        #expect(!ids.contains("vaultwarden"))
        #expect(!ids.contains("uptime-kuma"))
        for app in catalog.apps {
            #expect(app.source == "linuxserver")
            #expect(app.image?.hasPrefix("lscr.io/linuxserver/") == true)
            #expect(app.unsupportedReasons.isEmpty)
            #expect(app.isInstallable)
            #expect(!app.compose.contains("/dev/dri"))
            #expect(!app.compose.contains("DOCKER_MODS"))
            #expect(!app.compose.lowercased().contains("network_mode"))
            #expect(!app.compose.contains("privileged"))
            #expect(app.volumes.contains { $0.containerPath == "/config" && $0.kind == "volume" })
            #expect(AppCatalogArch.supports(arches: app.arches, deviceArch: "arm64"))
            #expect(AppCatalogArch.supports(arches: app.arches, deviceArch: "x86_64"))
        }
    }

    @Test func `jellyfin is the proof app with optional discovery and hidden server url`() throws {
        let jellyfin = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "jellyfin" })
        #expect(jellyfin.ports.contains { $0.container == 8_096 && $0.ui })
        #expect(jellyfin.ports.contains { $0.container == 7_359 && $0.proto == "udp" })
        #expect(jellyfin.ports.contains { $0.container == 1_900 && $0.proto == "udp" })
        #expect(jellyfin.volumes.contains { $0.containerPath == "/data/tvshows" && $0.kind == "folder" })
        #expect(jellyfin.volumes.contains { $0.containerPath == "/data/movies" && $0.kind == "folder" })
        #expect(jellyfin.envSchema.contains { $0.name == "PUID" })
        #expect(jellyfin.envSchema.contains { $0.name == "JELLYFIN_PublishedServerUrl" })
        let fields = AppTemplate.fields(from: jellyfin, puid: "501", pgid: "20", timezone: "UTC")
        #expect(!fields.contains { $0.envName == "JELLYFIN_PublishedServerUrl" })
        #expect(fields.contains { $0.envName == "PUID" && $0.defaultValue == "501" })
        #expect(fields.contains { $0.volumePath == "/data/tvshows" && $0.required == false })
        #expect(fields.contains { $0.volumePath == "/data/movies" && $0.required == false })
        #expect(!fields.contains { $0.volumePath == "/config" })
        var values = AppTemplate.seedValues(fields)
        values["port-8096-tcp"] = "8096"
        values["port-7359-udp"] = "7359"
        values["port-1900-udp"] = "1900"
        let rendered = try AppTemplate.render(
            entry: jellyfin, values: values, lanBind: "192.168.8.10",
        )
        #expect(rendered.env["JELLYFIN_PublishedServerUrl"] == "http://192.168.8.10:8096")
        #expect(!rendered.compose.contains("/dev/dri"))
    }

    @Test func `qbittorrent locksteps webui and keeps torrent udp`() throws {
        let qbit = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "qbittorrent" })
        let fields = AppTemplate.fields(from: qbit)
        #expect(!fields.contains { $0.envName == "WEBUI_PORT" })
        #expect(!fields.contains { $0.envName == "TORRENTING_PORT" })
        #expect(fields.contains { $0.portSpec?.proto == "udp" && $0.portSpec?.container == 6_881 })
        #expect(fields.contains { $0.volumePath == "/downloads" && $0.required == false })
        var values = AppTemplate.seedValues(fields)
        values["port-8080-tcp"] = "9090"
        values["port-6881-tcp"] = "6881"
        values["port-6881-udp"] = "6881"
        let rendered = try AppTemplate.render(entry: qbit, values: values)
        #expect(rendered.env["WEBUI_PORT"] == "9090")
        #expect(rendered.env["TORRENTING_PORT"] == "6881")
        #expect(rendered.compose.contains("6881:6881/udp") || rendered.compose.contains("udp"))
    }

    @Test func `nextcloud opens https on 443 and requires data`() throws {
        let nextcloud = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "nextcloud" })
        #expect(nextcloud.ui.scheme == "https")
        #expect(nextcloud.ports.contains { $0.container == 443 && $0.ui })
        let fields = AppTemplate.fields(from: nextcloud)
        #expect(fields.contains { $0.volumePath == "/data" && $0.required })
    }

    @Test func `code-server password is a secret and proxy stays direct`() throws {
        let code = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "code-server" })
        #expect(code.ui.proxy == "direct")
        let fields = AppTemplate.fields(from: code)
        #expect(fields.contains { $0.envName == "PASSWORD" && $0.kind == "secret" })
        #expect(!fields.contains { $0.envName == "PROXY_DOMAIN" })
    }

    @Test func `plex claim and version stay on the form`() throws {
        let plex = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "plex" })
        let fields = AppTemplate.fields(from: plex)
        #expect(fields.contains { $0.envName == "VERSION" && $0.kind == "select" })
        #expect(fields.contains { $0.envName == "PLEX_CLAIM" && $0.kind == "secret" && $0.required == false })
        #expect(fields.contains { $0.volumePath == "/movies" && $0.required })
        #expect(!plex.compose.lowercased().contains("network_mode"))
    }

    @Test func `home assistant publishes 8123 without host net or devices`() throws {
        let ha = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "homeassistant" })
        #expect(ha.ports.contains { $0.container == 8_123 && $0.ui })
        #expect(!ha.compose.contains("devices"))
        #expect(!ha.compose.lowercased().contains("network_mode"))
        #expect(!ha.compose.lowercased().contains("host network"))
    }

    @Test func `config named volume lands under the Workload dir`() throws {
        let jellyfin = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "jellyfin" })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bv-lsio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let render = try ComposeAllowlist.render(
            yaml: jellyfin.compose, workloadID: "jf1", stateDir: dir, bindHost: "192.168.8.10",
        )
        #expect(render.namedVolumes.contains("config"))
        #expect(render.yaml.contains("\(dir.path)/volumes/config"))
        #expect(!render.yaml.contains("/dev/dri"))
        #expect(render.publishedPorts.contains { $0.hostPort == 8_096 })
    }

    @Test func `builtin origin syncs without HTTP`() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try ImageRepository(
                id: "lsio",
                name: LinuxServerAppCatalog.catalogName,
                url: LinuxServerAppCatalog.originURL,
                isBuiltIn: true,
                repoType: "apps",
                lastSyncedAt: nil,
                lastError: nil,
                syncStatus: "idle",
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }
        let fetcher = RecordingLinuxServerFetcher()
        let service = RepositorySyncService(dbPool: pool, fetcher: fetcher)
        try await service.sync(repositoryID: "lsio")
        #expect(await fetcher.urls.isEmpty)
        let rows = try await pool.read { db in try AppCatalogRecord.fetchAll(db) }
        #expect(rows.contains { $0.slug == "jellyfin" && $0.source == "linuxserver" })
        #expect(rows.allSatisfy { $0.source == "linuxserver" })
    }
}

private actor RecordingLinuxServerFetcher: CatalogURLFetching {
    var urls: [URL] = []

    func fetch(url: URL) async throws -> Data {
        urls.append(url)
        throw BarkVisorError.repositorySyncFailed("should not fetch")
    }
}
