import Foundation
import Testing
@testable import BarkVisorCore

struct BigBearAppCatalogTests {
    @Test func `whoami is installable with digest and tcp port`() throws {
        let files = sample(
            slug: "whoami",
            appJSON: whoamiAppJSON(),
            compose: """
            services:
              whoami:
                image: traefik/whoami:v1.10@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                ports:
                  - "8080:80"
                restart: unless-stopped
            """,
        )
        let catalog = try BigBearAppCatalog.parse(files: files)
        let app = try #require(catalog.apps.first)
        #expect(app.id == "whoami")
        #expect(app.name == "Whoami")
        #expect(app.source == "big-bear-universal")
        #expect(app.arches == ["x86_64", "arm64"])
        #expect(app.unsupportedReasons.isEmpty)
        #expect(app.digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(app.image == "traefik/whoami:v1.10")
        #expect(app.ports.contains { $0.host == 8_080 && $0.container == 80 && $0.proto == "tcp" })
        #expect(app.ui.proxy == "direct")
        #expect(app.ui.scheme == "http")
        #expect(AppCatalogArch.supports(arches: app.arches, deviceArch: "arm64"))
        #expect(AppCatalogArch.supports(arches: app.arches, deviceArch: "amd64"))
    }

    @Test func `converted and example apps are ignored`() throws {
        var files = sample(
            slug: "whoami",
            appJSON: whoamiAppJSON(),
            compose: "services:\n  whoami:\n    image: traefik/whoami\n",
        )
        files["converted/whoami/app.json"] = Data(whoamiAppJSON().utf8)
        files["converted/whoami/docker-compose.yml"] = Data("services: {}\n".utf8)
        files["apps/_example/app.json"] = Data(whoamiAppJSON().utf8)
        files["apps/_example/docker-compose.yml"] = Data("services:\n  x:\n    image: alpine\n".utf8)
        let catalog = try BigBearAppCatalog.parse(files: files)
        #expect(catalog.apps.map(\.id) == ["whoami"])
    }

    @Test func `docker sock marks the card unsupported`() throws {
        let files = sample(
            slug: "portainer",
            appJSON: appJSON(id: "portainer", name: "Portainer"),
            compose: """
            services:
              app:
                image: portainer/portainer-ce
                ports:
                  - 9000:9000
                volumes:
                  - portainer_data:/data
                  - /var/run/docker.sock:/var/run/docker.sock
            volumes:
              portainer_data:
            """,
        )
        let app = try BigBearAppCatalog.parse(files: files).apps[0]
        #expect(app.unsupportedReasons.contains("docker.sock"))
        #expect(!app.isInstallable)
    }

    @Test func `privileged and host net and devices are named`() throws {
        let files = sample(
            slug: "homebridge",
            appJSON: appJSON(id: "homebridge", name: "Homebridge"),
            compose: """
            services:
              app:
                image: homebridge/homebridge
                privileged: true
                network_mode: host
                devices:
                  - /dev/ttyUSB0
            """,
        )
        let app = try BigBearAppCatalog.parse(files: files).apps[0]
        #expect(app.unsupportedReasons.contains("privileged"))
        #expect(app.unsupportedReasons.contains("host network"))
        #expect(app.unsupportedReasons.contains("devices"))
    }

    @Test func `plex host net is rewritten to port 32400`() throws {
        let files = sample(
            slug: "plex",
            appJSON: appJSON(
                id: "plex",
                name: "Plex",
                env: [
                    ["name": "PLEX_CLAIM", "default": "", "description": "Claim", "required": false],
                ],
            ),
            compose: """
            services:
              big-bear-plex:
                image: linuxserver/plex:1.43.3@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
                network_mode: host
                volumes:
                  - plex_config:/config
                  - plex_movies:/movies
            volumes:
              plex_config:
              plex_movies:
            """,
        )
        let app = try BigBearAppCatalog.parse(files: files).apps[0]
        #expect(!app.unsupportedReasons.contains("host network"))
        #expect(app.ports.contains { $0.host == 32_400 && $0.container == 32_400 })
        #expect(app.compose.contains("32400"))
        #expect(!app.compose.contains("network_mode"))
        #expect(app.volumes.contains { $0.name == "plex_movies" && $0.kind == "folder" })
        #expect(app.volumes.contains { $0.name == "plex_config" && $0.kind == "volume" })
        #expect(app.envSchema.contains { $0.name == "PLEX_CLAIM" && $0.kind == "secret" })
        #expect(app.digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(app.ui.proxy == "direct")
    }

    @Test func `pihole ports keep udp from compose`() throws {
        let files = sample(
            slug: "pihole",
            appJSON: appJSON(id: "pihole", name: "Pi-hole"),
            compose: """
            services:
              pihole:
                image: pihole/pihole
                ports:
                  - "53:53/udp"
                  - "67:67/udp"
                  - "8080:80/tcp"
            """,
        )
        let app = try BigBearAppCatalog.parse(files: files).apps[0]
        #expect(app.ports.contains { $0.container == 53 && $0.proto == "udp" })
        #expect(app.ports.contains { $0.container == 67 && $0.proto == "udp" })
        #expect(app.ports.contains { $0.container == 80 && $0.proto == "tcp" })
    }

    @Test func `internal hostnames are hidden and passwords stay`() throws {
        #expect(BigBearAppCatalog.shouldHideEnv("DB_HOSTNAME"))
        #expect(BigBearAppCatalog.shouldHideEnv("POSTGRES_HOST"))
        #expect(BigBearAppCatalog.shouldHideEnv("PAPERLESS_REDIS"))
        #expect(BigBearAppCatalog.shouldHideEnv("COMPOSE_PROJECT_NAME"))
        #expect(!BigBearAppCatalog.shouldHideEnv("DB_PASSWORD"))
        let files = sample(
            slug: "immich",
            appJSON: appJSON(
                id: "immich",
                name: "Immich",
                env: [
                    ["name": "DB_HOSTNAME", "default": "", "description": "db", "required": false],
                    ["name": "DB_PASSWORD", "default": "secret", "description": "pw", "required": true],
                    ["name": "ENABLE_MACHINE_LEARNING", "default": "true", "description": "ml", "required": false],
                ],
            ),
            compose: """
            services:
              immich-server:
                image: ghcr.io/immich-app/immich-server
                ports:
                  - "2283:2283"
            """,
        )
        let app = try BigBearAppCatalog.parse(files: files).apps[0]
        #expect(!app.envSchema.contains { $0.name == "DB_HOSTNAME" })
        let password = try #require(app.envSchema.first { $0.name == "DB_PASSWORD" })
        #expect(password.kind == "secret")
        #expect(password.required)
        let flag = try #require(app.envSchema.first { $0.name == "ENABLE_MACHINE_LEARNING" })
        #expect(flag.kind == "bool")
        #expect(app.ui.proxy == "direct")
    }

    @Test func `cap_add tun is unsupported`() throws {
        let files = sample(
            slug: "gluetun",
            appJSON: appJSON(id: "gluetun", name: "Gluetun"),
            compose: """
            services:
              vpn:
                image: qmcgaw/gluetun
                cap_add:
                  - NET_ADMIN
                devices:
                  - /dev/net/tun:/dev/net/tun
            """,
        )
        let app = try BigBearAppCatalog.parse(files: files).apps[0]
        #expect(app.unsupportedReasons.contains("cap_add"))
        #expect(app.unsupportedReasons.contains("devices"))
    }

    @Test func `arch mismatch helper does not hide empty arches`() {
        #expect(AppCatalogArch.supports(arches: [], deviceArch: "arm64"))
        #expect(!AppCatalogArch.supports(arches: ["amd64"], deviceArch: "arm64"))
        #expect(AppCatalogArch.supports(arches: ["amd64"], deviceArch: "x86_64"))
    }

    @Test func `host bind mounts are unsupported unless they are docker sock`() throws {
        let files = sample(
            slug: "gitea",
            appJSON: appJSON(id: "gitea", name: "Gitea"),
            compose: """
            services:
              app:
                image: gitea/gitea
                ports:
                  - "3000:3000"
                volumes:
                  - gitea_data:/data
                  - /etc/localtime:/etc/localtime:ro
            volumes:
              gitea_data:
            """,
        )
        let app = try BigBearAppCatalog.parse(files: files).apps[0]
        #expect(app.unsupportedReasons.contains("bind"))
        #expect(!app.isInstallable)
    }

    @Test func `deflated zip of apps inflates`() throws {
        let zip = dataFromHex(
            [
                "504b03041400000008003d75295d37160efc9f000000e600000014000000",
                "617070732f77686f616d692f6170702e6a736f6e358e4b0ac3300c44efa2",
                "75b22b5df80e5d77514a516c110be20fb6ec1242ee5e39d0ddbce109cd01",
                "81041d0a8239801d18f8fa848161828881949f7fb628b4a6b26bf720c7a8",
                "554dadd8212dbcce0b61995be44ea5e206e7049d6bd3640ecd42d647b617",
                "0216eb591b69852a98176070f71bbcd57394b7b4078a32448a9d4b8a033f",
                "1d0be3b25d07c36c3c8c6a3d5d3bbd48d64919c52b6912ce75fc3ecf1f50",
                "4b03041400000008003d75295d75d6c09e290000002e0000001e00000061",
                "7070732f77686f616d692f646f636b65722d636f6d706f73652e796d6c2b",
                "4e2d2acb4c4e2db6e2525028cfc84fcccd04b11414327313d353ad144a8a",
                "1253d332b3f521525c00504b010214031400000008003d75295d37160efc",
                "9f000000e600000014000000000000000000000080010000000061707073",
                "2f77686f616d692f6170702e6a736f6e504b010214031400000008003d75",
                "295d75d6c09e290000002e0000001e00000000000000000000008001d100",
                "0000617070732f77686f616d692f646f636b65722d636f6d706f73652e79",
                "6d6c504b050600000000020002008e000000360100000000",
            ].joined(),
        )
        let catalog = try BigBearAppCatalog.parseZip(zip)
        #expect(catalog.apps.map(\.id) == ["whoami"])
    }

    @Test func `zip of apps parses and skips converted`() throws {
        let whoami = sample(
            slug: "whoami",
            appJSON: whoamiAppJSON(),
            compose: "services:\n  whoami:\n    image: traefik/whoami\n",
        )
        var files: [String: Data] = [:]
        for (path, data) in whoami {
            files["big-bear-universal-apps-main/\(path)"] = data
        }
        files["big-bear-universal-apps-main/converted/whoami/app.json"] = Data(whoamiAppJSON().utf8)
        let zip = try storedZip(files)
        let catalog = try BigBearAppCatalog.parseZip(zip)
        #expect(catalog.apps.map(\.id) == ["whoami"])
    }

    @Test func `application document uses compose from the entry`() throws {
        let entry = AppCatalogEntryDTO(
            id: "whoami",
            name: "Whoami",
            category: "Apps",
            arches: ["arm64"],
            compose: "services:\n  whoami:\n    image: traefik/whoami\n",
        )
        let doc = entry.applicationDocument(name: "my-whoami")
        #expect(doc["kind"] as? String == WorkloadSpec.kindApplication)
        let spec = try #require(doc["spec"] as? [String: Any])
        #expect(spec["runtime"] as? String == WorkloadSpec.runtimeDevice)
        #expect(spec["compose"] as? String == entry.compose)
        let metadata = try #require(doc["metadata"] as? [String: Any])
        #expect(metadata["name"] as? String == "my-whoami")
    }

    private func sample(slug: String, appJSON: String, compose: String) -> [String: Data] {
        [
            "apps/\(slug)/app.json": Data(appJSON.utf8),
            "apps/\(slug)/docker-compose.yml": Data(compose.utf8),
        ]
    }

    private func whoamiAppJSON() -> String {
        appJSON(id: "whoami", name: "Whoami", arches: ["amd64", "arm64"])
    }

    private func appJSON(
        id: String,
        name: String,
        arches: [String] = ["amd64", "arm64"],
        env: [[String: Any]] = [],
    ) -> String {
        let envData = (try? JSONSerialization.data(withJSONObject: env)) ?? Data("[]".utf8)
        let envText = String(data: envData, encoding: .utf8) ?? "[]"
        let archText = arches.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "metadata": {
            "id": "\(id)",
            "name": "\(name)",
            "tagline": "\(name) tagline",
            "description": "\(name) description",
            "category": "Media",
            "source": "big-bear-universal"
          },
          "visual": { "icon": "https://example.com/\(id).png" },
          "technical": { "architectures": [\(archText)] },
          "deployment": { "environment_variables": \(envText) },
          "ui": { "scheme": "http", "path": "", "tips": {} }
        }
        """
    }

    private func storedZip(_ files: [String: Data]) throws -> Data {
        var locals = Data()
        var central = Data()
        for name in files.keys.sorted() {
            guard let payload = files[name], let nameData = name.data(using: .utf8) else { continue }
            let offset = UInt32(locals.count)
            locals.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            locals.append(contentsOf: [0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            locals.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            locals.append(contentsOf: le32(UInt32(payload.count)))
            locals.append(contentsOf: le32(UInt32(payload.count)))
            locals.append(contentsOf: le16(UInt16(nameData.count)))
            locals.append(contentsOf: le16(0))
            locals.append(nameData)
            locals.append(payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(contentsOf: [0x14, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            central.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            central.append(contentsOf: le32(UInt32(payload.count)))
            central.append(contentsOf: le32(UInt32(payload.count)))
            central.append(contentsOf: le16(UInt16(nameData.count)))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le32(0))
            central.append(contentsOf: le32(offset))
            central.append(nameData)
        }
        let cdOffset = UInt32(locals.count)
        let cdSize = UInt32(central.count)
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00])
        eocd.append(contentsOf: le16(UInt16(files.count)))
        eocd.append(contentsOf: le16(UInt16(files.count)))
        eocd.append(contentsOf: le32(cdSize))
        eocd.append(contentsOf: le32(cdOffset))
        eocd.append(contentsOf: le16(0))
        var out = Data()
        out.append(locals)
        out.append(central)
        out.append(eocd)
        return out
    }

    private func dataFromHex(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        var i = 0
        while i + 1 < chars.count {
            let hi = chars[i].hexDigitValue ?? 0
            let lo = chars[i + 1].hexDigitValue ?? 0
            bytes.append(UInt8((hi << 4) | lo))
            i += 2
        }
        return Data(bytes)
    }

    private func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }
}
