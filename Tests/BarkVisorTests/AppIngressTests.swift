import Foundation
import Testing
@testable import BarkVisorCore

struct AppIngressTests {
    @Test func `unknown catalog proxy is direct`() {
        #expect(AppIngress.resolvedMode(catalogProxy: nil, override: nil) == "direct")
        #expect(AppIngress.resolvedMode(catalogProxy: "weird", override: nil) == "direct")
        #expect(AppIngress.usesPrefix(catalogProxy: nil, ingress: WorkloadIngress()) == false)
        let env = AppIngress.managedEnv(
            id: "old",
            names: ["SUBFOLDER"],
            catalogProxy: nil,
            ingress: nil,
            scheme: "http",
            host: "192.168.1.20",
            listenPort: 7_777,
        )
        #expect(env.isEmpty)
    }

    @Test func `prefix is opt-out and override wins`() {
        let on = WorkloadIngress(enabled: true, mode: "prefix")
        #expect(AppIngress.usesPrefix(catalogProxy: "direct", ingress: on))
        let off = WorkloadIngress(enabled: false, mode: "prefix")
        #expect(AppIngress.usesPrefix(catalogProxy: "prefix", ingress: off) == false)
        #expect(AppIngress.isEnabled(nil))
    }

    @Test func `managed env writes mapped names and barkvisor keys`() {
        let ingress = WorkloadIngress(enabled: true, mode: "prefix")
        let env = AppIngress.managedEnv(
            id: "app-1",
            names: ["SUBFOLDER", "APP_URL", "GITEA__server__ROOT_URL", "GITEA__server__DOMAIN"],
            catalogProxy: "prefix",
            ingress: ingress,
            scheme: "http",
            host: "192.168.1.20",
            listenPort: 7_777,
        )
        #expect(env["SUBFOLDER"] == "/go/app-1/")
        #expect(env["APP_URL"] == "http://192.168.1.20:7777/go/app-1/")
        #expect(env["GITEA__server__ROOT_URL"] == "http://192.168.1.20:7777/go/app-1/")
        #expect(env["GITEA__server__DOMAIN"] == "192.168.1.20")
        #expect(env["BARKVISOR_BASE_PATH"] == "/go/app-1/")
        #expect(env["BARKVISOR_PUBLIC_URL"] == "http://192.168.1.20:7777/go/app-1/")
        #expect(env["PROXY_DOMAIN"] == nil)
    }

    @Test func `toggle off strips managed keys and extra cannot override them`() {
        let existing = [
            "SUBFOLDER": "/old/",
            "PUID": "1000",
            "APP_URL": "http://old",
        ]
        let extra = ["SUBFOLDER": "/hack/", "DEBUG": "1"]
        let merged = AppIngress.mergeEnv(
            existing: existing,
            extra: extra,
            managed: ["SUBFOLDER": "/go/x/"],
            enabled: false,
        )
        #expect(merged?["SUBFOLDER"] == nil)
        #expect(merged?["APP_URL"] == nil)
        #expect(merged?["PUID"] == "1000")
        #expect(merged?["DEBUG"] == "1")
        let on = AppIngress.mergeEnv(
            existing: existing,
            extra: extra,
            managed: ["SUBFOLDER": "/go/x/"],
            enabled: true,
        )
        #expect(on?["SUBFOLDER"] == "/go/x/")
        #expect(on?["DEBUG"] == "1")
    }

    @Test func `open url is go path for prefix and lan for direct`() {
        let prefix = AppIngress.openURL(
            id: "abc",
            catalogProxy: "prefix",
            ingress: WorkloadIngress(),
            lanURL: "http://192.168.1.20:32400",
            listenHost: "192.168.1.20",
            listenPort: 7_777,
        )
        #expect(prefix == "http://192.168.1.20:7777/go/abc/")
        let direct = AppIngress.openURL(
            id: "abc",
            catalogProxy: "direct",
            ingress: WorkloadIngress(),
            lanURL: "http://192.168.1.20:32400",
            listenHost: "192.168.1.20",
            listenPort: 7_777,
        )
        #expect(direct == "http://192.168.1.20:32400")
    }

    @Test func `strip removes barkvisor cookies and authorization`() {
        let stripped = AppIngress.stripForwardHeaders([
            ("Authorization", "Bearer secret"),
            ("Cookie", "barkvisor=tok; theme=dark; BARKVISOR_SESSION=x"),
            ("Accept", "text/html"),
        ])
        #expect(!stripped.contains(where: { $0.0.lowercased() == "authorization" }))
        let cookie = stripped.first { $0.0.lowercased() == "cookie" }?.1 ?? ""
        #expect(cookie.contains("theme=dark"))
        #expect(!cookie.lowercased().contains("barkvisor"))
        #expect(stripped.contains(where: { $0.0 == "Accept" }))
    }

    @Test func `loopback url is localhost only`() throws {
        let url = try AppIngress.loopbackURL(port: 8_080, path: "/go/abc/", query: "q=1")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 8_080)
        #expect(url.absoluteString.hasPrefix("http://127.0.0.1:8080/go/abc/"))
        #expect(url.query == "q=1")
        #expect(throws: BarkVisorError.self) {
            try AppIngress.loopbackURL(port: 0, path: "/", query: nil)
        }
    }

    @Test func `freshrss catalog is prefix with hidden subfolder`() throws {
        let app = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "freshrss" })
        #expect(app.ui.proxy == "prefix")
        #expect(app.ui.basePathEnv.contains("SUBFOLDER"))
        let fields = AppTemplate.fields(from: app)
        #expect(!fields.contains { $0.envName == "SUBFOLDER" })
        var values = AppTemplate.seedValues(fields)
        values["port-80-tcp"] = "80"
        let rendered = try AppTemplate.render(
            entry: app,
            values: values,
            lanBind: "192.168.1.20",
            ingress: WorkloadIngress(enabled: true),
            workloadID: "rss1",
            listenPort: 7_777,
        )
        #expect(rendered.env["SUBFOLDER"] == "/go/rss1/")
        #expect(rendered.env["BARKVISOR_PUBLIC_URL"] == "http://192.168.1.20:7777/go/rss1/")
        let off = try AppTemplate.render(
            entry: app,
            values: values,
            lanBind: "192.168.1.20",
            ingress: WorkloadIngress(enabled: false),
            workloadID: "rss1",
            listenPort: 7_777,
        )
        #expect(off.env["SUBFOLDER"] == nil)
        #expect(off.env["BARKVISOR_BASE_PATH"] == nil)
    }

    @Test func `plex and code-server stay direct`() throws {
        let plex = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "plex" })
        #expect(plex.ui.proxy == "direct")
        let code = try #require(try LinuxServerAppCatalog.load().apps.first { $0.id == "code-server" })
        #expect(code.ui.proxy == "direct")
        #expect(!code.ui.basePathEnv.contains("SUBFOLDER"))
        let fields = AppTemplate.fields(from: plex)
        var values = AppTemplate.seedValues(fields)
        values["port-32400-tcp"] = "32400"
        values["path-movies"] = "/tmp/movies"
        values["path-tv"] = "/tmp/tv"
        let rendered = try AppTemplate.render(
            entry: plex, values: values, ingress: WorkloadIngress(enabled: true),
        )
        #expect(rendered.env["SUBFOLDER"] == nil)
    }

    @Test func `is proxy path covers go and home hop`() {
        #expect(AppIngress.isProxyPath("/go/abc/"))
        #expect(AppIngress.isProxyPath("/home/devices/h1/go/abc/web"))
        #expect(AppIngress.isProxyPath("/api/vms") == false)
        #expect(AppIngress.isProxyPath("/devices/h1") == false)
    }
}
