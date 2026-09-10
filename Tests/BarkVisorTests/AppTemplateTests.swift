import Foundation
import Testing
@testable import BarkVisorCore

struct AppTemplateTests {
    @Test func `immich asks for upload and database password not compose yaml`() {
        let entry = AppCatalogEntryDTO(
            id: "immich",
            name: "Immich",
            category: "Media",
            arches: ["arm64"],
            compose: """
            services:
              server:
                image: ghcr.io/immich-app/immich-server
                ports:
                  - "2283:2283"
                volumes:
                  - immich_upload:/usr/src/app/upload
                  - pgdata:/var/lib/postgresql/data
                  - model-cache:/cache
            volumes:
              immich_upload:
              pgdata:
              model-cache:
            """,
            envSchema: [
                AppCatalogEnvVar(name: "DB_PASSWORD", defaultValue: "casaos", required: true, kind: "secret"),
                AppCatalogEnvVar(name: "POSTGRES_PASSWORD", defaultValue: "casaos", required: true, kind: "secret"),
                AppCatalogEnvVar(name: "DB_HOSTNAME", defaultValue: "immich-postgres", kind: "text"),
            ],
            volumes: [
                AppCatalogVolume(containerPath: "/usr/src/app/upload", name: "immich_upload", kind: "folder"),
                AppCatalogVolume(containerPath: "/var/lib/postgresql/data", name: "pgdata", kind: "volume"),
                AppCatalogVolume(containerPath: "/cache", name: "model-cache", kind: "volume"),
            ],
            ports: [AppCatalogPort(container: 2_283, host: 2_283, proto: "tcp", ui: true)],
        )
        let fields = AppTemplate.fields(from: entry)
        #expect(fields.contains { $0.kind == "path" && $0.required && $0.volumePath == "/usr/src/app/upload" })
        #expect(!fields.contains { $0.volumePath == "/var/lib/postgresql/data" })
        #expect(!fields.contains { $0.volumePath == "/cache" })
        #expect(fields.contains { $0.kind == "secret" && $0.required })
        #expect(fields.count(where: { $0.kind == "secret" }) == 1)
        #expect(!fields.contains { $0.envName == "DB_HOSTNAME" })
        let secret = fields.first { $0.kind == "secret" }
        #expect(secret?.defaultValue == nil)
    }

    @Test func `plex movies and tv are required and config is auto`() throws {
        let entry = plexEntry()
        let fields = AppTemplate.fields(from: entry, puid: "501", pgid: "20", timezone: "America/Los_Angeles")
        #expect(fields.contains { $0.volumePath == "/movies" && $0.required })
        #expect(fields.contains { $0.volumePath == "/tv" && $0.required })
        #expect(!fields.contains { $0.volumePath == "/config" })
        let puid = try #require(fields.first { $0.envName == "PUID" })
        #expect(puid.defaultValue == "501")
        let tz = try #require(fields.first { $0.envName == "TZ" })
        #expect(tz.defaultValue == "America/Los_Angeles")
        let claim = try #require(fields.first { $0.envName == "PLEX_CLAIM" })
        #expect(claim.kind == "secret")
        #expect(claim.required == false)
        #expect(fields.contains { $0.kind == "port" && $0.portSpec?.container == 32_400 })
    }

    @Test func `sonarr tv and downloads are optional`() {
        let entry = AppCatalogEntryDTO(
            id: "sonarr",
            name: "Sonarr",
            category: "Media",
            arches: ["arm64"],
            compose: "services:\n  sonarr:\n    image: lscr.io/linuxserver/sonarr\n",
            volumes: [
                AppCatalogVolume(containerPath: "/config", name: "sonarr_config", kind: "volume"),
                AppCatalogVolume(containerPath: "/tv", name: "sonarr_tv", kind: "folder"),
                AppCatalogVolume(containerPath: "/downloads", name: "sonarr_downloads", kind: "folder"),
            ],
        )
        let fields = AppTemplate.fields(from: entry)
        #expect(fields.contains { $0.volumePath == "/tv" && $0.required == false })
        #expect(fields.contains { $0.volumePath == "/downloads" && $0.required == false })
    }

    @Test func `qbittorrent keeps udp torrent port and locksteps webuiport`() throws {
        let entry = AppCatalogEntryDTO(
            id: "qbittorrent",
            name: "qBittorrent",
            category: "Download",
            arches: ["arm64"],
            compose: """
            services:
              qb:
                image: lscr.io/linuxserver/qbittorrent
                ports:
                  - "8080:8080"
                  - "6881:6881"
                  - "6881:6881/udp"
                environment:
                  - WEBUI_PORT=8080
                  - TORRENTING_PORT=6881
            """,
            envSchema: [
                AppCatalogEnvVar(name: "WEBUI_PORT", defaultValue: "8080", kind: "text"),
                AppCatalogEnvVar(name: "TORRENTING_PORT", defaultValue: "6881", kind: "text"),
                AppCatalogEnvVar(name: "PUID", defaultValue: "1000", kind: "text"),
            ],
            ports: [
                AppCatalogPort(container: 8_080, host: 8_080, proto: "tcp", ui: true),
                AppCatalogPort(container: 6_881, host: 6_881, proto: "tcp"),
                AppCatalogPort(container: 6_881, host: 6_881, proto: "udp"),
            ],
        )
        let fields = AppTemplate.fields(from: entry)
        #expect(!fields.contains { $0.envName == "WEBUI_PORT" })
        #expect(fields.contains { $0.portSpec?.proto == "udp" && $0.portSpec?.container == 6_881 })
        var values = AppTemplate.seedValues(fields)
        values["port-8080-tcp"] = "9090"
        values["port-6881-tcp"] = "6881"
        values["port-6881-udp"] = "6881"
        let rendered = try AppTemplate.render(entry: entry, values: values)
        #expect(rendered.env["WEBUI_PORT"] == "9090")
        #expect(rendered.env["TORRENTING_PORT"] == "6881")
        #expect(rendered.compose.contains("9090"))
    }

    @Test func `required empty field names the field`() {
        let entry = plexEntry()
        let fields = AppTemplate.fields(from: entry)
        let error = #expect(throws: BarkVisorError.self) {
            try AppTemplate.validate(fields, values: ["PUID": "501"])
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message.contains("Movies") || message.contains("required"))
    }

    @Test func `render writes media bind and keeps config as named volume`() throws {
        let entry = plexEntry()
        let fields = AppTemplate.fields(from: entry, puid: "501", pgid: "20", timezone: "UTC")
        var values = AppTemplate.seedValues(fields)
        values["path-movies"] = "/mnt/media/movies"
        values["path-tv"] = "/mnt/media/tv"
        values["port-32400-tcp"] = "32400"
        let rendered = try AppTemplate.render(
            entry: entry,
            values: values,
            extraFolders: [AppTemplateExtraFolder(hostPath: "/mnt/media/photos", containerPath: "/photos")],
        )
        #expect(rendered.sharedPaths.contains("/mnt/media/movies"))
        #expect(rendered.sharedPaths.contains("/mnt/media/photos"))
        #expect(rendered.compose.contains("/mnt/media/movies"))
        #expect(rendered.compose.contains("/photos"))
        #expect(!rendered.compose.contains("casaos"))
        #expect(rendered.env["PUID"] == "501")
        if let claim = rendered.env["PLEX_CLAIM"], !claim.isEmpty {
            #expect(claim != "casaos")
        }
    }

    @Test func `open ui uses scheme and path`() {
        let url = AppTemplate.openURL(scheme: "https", path: "/web", host: "192.168.1.20", port: 32_400)
        #expect(url == "https://192.168.1.20:32400/web")
    }

    @Test func `secret merge keeps omitted and redacted values`() {
        let merged = AppTemplate.mergeEnv(
            existing: ["DB_PASSWORD": "keep-me", "PUID": "1000"],
            incoming: ["DB_PASSWORD": "***", "PUID": "501"],
        )
        #expect(merged?["DB_PASSWORD"] == "keep-me")
        #expect(merged?["PUID"] == "501")
    }

    @Test func `redact env uses placeholder`() {
        let redacted = AppTemplate.redactEnv(["DB_PASSWORD": "hunter2", "PUID": "501"])
        #expect(redacted?["DB_PASSWORD"] == "***")
        #expect(redacted?["PUID"] == "501")
    }

    @Test func `password token key and claim are secrets`() {
        #expect(BigBearAppCatalog.inferKind(name: "API_KEY", defaultValue: nil) == "secret")
        #expect(BigBearAppCatalog.inferKind(name: "PLEX_CLAIM", defaultValue: nil) == "secret")
        #expect(BigBearAppCatalog.inferKind(name: "JWT_TOKEN", defaultValue: nil) == "secret")
        #expect(BigBearAppCatalog.inferKind(name: "SSH_PUBKEY", defaultValue: nil) != "secret")
    }

    @Test func `bool and select come from catalog values`() {
        #expect(BigBearAppCatalog.inferKind(name: "ENABLE_HW", defaultValue: "true") == "bool")
        #expect(BigBearAppCatalog.inferKind(name: "VERSION", defaultValue: "docker") == "select")
        #expect(
            BigBearAppCatalog.inferKind(name: "LOG_LEVEL", defaultValue: "info", options: ["debug", "info"])
                == "select",
        )
    }

    private func plexEntry() -> AppCatalogEntryDTO {
        AppCatalogEntryDTO(
            id: "plex",
            name: "Plex",
            category: "Media",
            arches: ["arm64"],
            compose: """
            services:
              plex:
                image: lscr.io/linuxserver/plex
                ports:
                  - "32400:32400"
                environment:
                  PUID: "1000"
                  PGID: "1000"
                  TZ: UTC
                  PLEX_CLAIM: casaos
                volumes:
                  - plex_config:/config
                  - plex_movies:/movies
                  - plex_tv:/tv
            volumes:
              plex_config:
              plex_movies:
              plex_tv:
            """,
            envSchema: [
                AppCatalogEnvVar(name: "PUID", defaultValue: "1000", kind: "text"),
                AppCatalogEnvVar(name: "PGID", defaultValue: "1000", kind: "text"),
                AppCatalogEnvVar(name: "TZ", defaultValue: "UTC", kind: "text"),
                AppCatalogEnvVar(name: "PLEX_CLAIM", defaultValue: "casaos", required: false, kind: "secret"),
                AppCatalogEnvVar(name: "UMASK", defaultValue: "022", kind: "text"),
            ],
            volumes: [
                AppCatalogVolume(containerPath: "/config", name: "plex_config", kind: "volume"),
                AppCatalogVolume(containerPath: "/movies", name: "plex_movies", kind: "folder"),
                AppCatalogVolume(containerPath: "/tv", name: "plex_tv", kind: "folder"),
            ],
            ports: [AppCatalogPort(container: 32_400, host: 32_400, proto: "tcp", ui: true)],
            ui: AppCatalogUI(scheme: "http", path: "/web"),
        )
    }
}
