import Foundation
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
struct ComposeAllowlistTests {
    private var stateDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bv-compose-\(UUID().uuidString)")
    }

    @Test func `whoami compose is rewritten with labels and named volumes`() throws {
        let dir = stateDir
        let yaml = """
        services:
          whoami:
            image: traefik/whoami
            ports:
              - "8080:80"
            volumes:
              - data:/config
            restart: unless-stopped
        volumes:
          data:
        """
        let render = try ComposeAllowlist.render(
            yaml: yaml, workloadID: "abc-123", stateDir: dir, bindHost: "192.168.8.10",
        )
        #expect(render.publishedPorts.contains { $0.hostPort == 8_080 && $0.containerPort == 80 })
        #expect(render.bindHost == "0.0.0.0")
        #expect(render.yaml.contains("0.0.0.0") || render.yaml.contains("host_ip"))
        #expect(render.namedVolumes == ["data"])
        #expect(render.yaml.contains("barkvisor.workload"))
        #expect(render.yaml.contains("abc-123"))
        #expect(render.yaml.contains("bv-abc-123-whoami"))
        #expect(render.yaml.contains("\(dir.path)/volumes/data"))
        #expect(!render.yaml.contains("privileged"))
    }

    @Test func `compose interpolation is rejected`() {
        let yaml = """
        services:
          x:
            image: ${FOO}
        """
        let keyed = """
        services:
          ${S}:
            image: alpine
        """
        for document in [yaml, keyed] {
            let error = #expect(throws: BarkVisorError.self) {
                _ = try ComposeAllowlist.render(
                    yaml: document, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
                )
            }
            guard case let .badRequest(message) = error else {
                Issue.record("expected badRequest")
                continue
            }
            #expect(message == "unsupported compose feature: interpolation")
        }
    }

    @Test func `environment list without values is rejected`() {
        let yaml = """
        services:
          x:
            image: alpine
            environment:
              - HOME
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: environment")
    }

    @Test func `env_file long form is rejected`() {
        let yaml = """
        services:
          x:
            image: alpine
            env_file:
              - path: /etc/passwd
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: env_file")
    }

    @Test func `privileged is rejected by name`() {
        let yaml = """
        services:
          x:
            image: alpine
            privileged: true
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: privileged")
    }

    @Test func `privileged string True is rejected`() {
        let yaml = """
        services:
          x:
            image: alpine
            privileged: "True"
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: privileged")
    }

    @Test func `host network is rejected by name`() {
        let yaml = """
        services:
          x:
            image: alpine
            network_mode: host
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: host network")
    }

    @Test func `bind escape is rejected`() {
        let yaml = """
        services:
          x:
            image: alpine
            volumes:
              - /etc:/etc
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: bind")
    }

    @Test func `relative project bind is rejected`() {
        let yaml = """
        services:
          x:
            image: alpine
            volumes:
              - .:/mnt
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: bind")
    }

    @Test func `bind type object is rejected`() {
        let yaml = """
        services:
          x:
            image: alpine
            volumes:
              - type: bind
                source: ./data
                target: /data
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: bind")
    }

    @Test func `named volume dest symlink outside volumes is rejected`() throws {
        let dir = stateDir
        let volumeRoot = dir.appendingPathComponent("volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeRoot, withIntermediateDirectories: true)
        let dest = volumeRoot.appendingPathComponent("data")
        try FileManager.default.createSymbolicLink(
            at: dest,
            withDestinationURL: URL(fileURLWithPath: "/etc", isDirectory: true),
        )
        let yaml = """
        services:
          x:
            image: alpine
            volumes:
              - data:/config
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: dir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: bind")
    }

    @Test func `named volume parent segments are rejected`() {
        let short = """
        services:
          x:
            image: alpine
            volumes:
              - a/../../etc:/etc
        """
        let parent = """
        services:
          x:
            image: alpine
            volumes:
              - ..:/etc
        """
        let object = """
        services:
          x:
            image: alpine
            volumes:
              - type: volume
                source: a/../../etc
                target: /etc
        """
        for yaml in [short, parent, object] {
            let error = #expect(throws: BarkVisorError.self) {
                _ = try ComposeAllowlist.render(
                    yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
                )
            }
            guard case let .badRequest(message) = error else {
                Issue.record("expected badRequest")
                continue
            }
            #expect(message == "unsupported compose feature: bind")
        }
    }

    @Test func `malformed ports are rejected`() {
        let short = """
        services:
          x:
            image: alpine
            ports:
              - "8080-8090:80"
        """
        let object = """
        services:
          x:
            image: alpine
            ports:
              - target: 80
        """
        for yaml in [short, object] {
            let error = #expect(throws: BarkVisorError.self) {
                _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
            }
            guard case let .badRequest(message) = error else {
                Issue.record("expected badRequest")
                continue
            }
            #expect(message == "unsupported compose feature: ports")
        }
    }

    @Test func `cap_add and devices are rejected`() {
        let cap = """
        services:
          x:
            image: alpine
            cap_add: [NET_ADMIN]
        """
        let devices = """
        services:
          x:
            image: alpine
            devices:
              - /dev/dri
        """
        for yaml in [cap, devices] {
            let error = #expect(throws: BarkVisorError.self) {
                _ = try ComposeAllowlist.render(
                    yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
                )
            }
            guard case let .badRequest(message) = error else { continue }
            #expect(message.hasPrefix("unsupported compose feature:"))
        }
    }

    @Test func `published ports bind 0.0.0.0 including UDP`() throws {
        let yaml = """
        services:
          media:
            image: alpine
            ports:
              - "8096:8096"
              - "1900:1900/udp"
              - "0.0.0.0:5353:5353/udp"
        """
        let render = try ComposeAllowlist.render(
            yaml: yaml, workloadID: "app-1", stateDir: stateDir, bindHost: "192.168.8.10",
        )
        #expect(render.publishedPorts.count == 3)
        #expect(render.publishedPorts.contains {
            $0.hostPort == 8_096 && $0.containerPort == 8_096 && $0.proto == "tcp"
                && $0.hostAddress == "0.0.0.0"
        })
        #expect(render.publishedPorts.contains {
            $0.hostPort == 1_900 && $0.proto == "udp" && $0.hostAddress == "0.0.0.0"
        })
        #expect(render.publishedPorts.contains {
            $0.hostPort == 5_353 && $0.proto == "udp" && $0.hostAddress == "0.0.0.0"
        })
        #expect(
            render.yaml.contains("host_ip: 0.0.0.0")
                || render.yaml.contains("host_ip: '0.0.0.0'")
                || render.yaml.contains("host_ip: \"0.0.0.0\""),
        )
        let rules = ApplicationLifecycleService.portRules(render.publishedPorts)
        try PortRegistry.assertUnique(rules)
        #expect(rules.contains { $0.hostPort == 1_900 && $0.protocol == "udp" })
        #expect(rules.contains { $0.hostPort == 8_096 && $0.protocol == "tcp" })
    }

    @Test func `plex host network is rewritten to published 32400`() throws {
        let yaml = """
        services:
          plex:
            image: lscr.io/linuxserver/plex:latest
            network_mode: host
            volumes:
              - config:/config
        volumes:
          config:
        """
        let render = try ComposeAllowlist.render(
            yaml: yaml, workloadID: "plex-1", stateDir: stateDir, bindHost: "192.168.8.10",
        )
        #expect(!render.yaml.contains("network_mode"))
        #expect(render.publishedPorts.contains {
            $0.hostPort == 32_400 && $0.containerPort == 32_400 && $0.proto == "tcp"
                && $0.hostAddress == "0.0.0.0"
        })
        #expect(render.yaml.contains("32400"))
    }

    @Test func `plex image match is the image name not a substring`() {
        #expect(ComposePorts.isPlexImage("lscr.io/linuxserver/plex:latest"))
        #expect(ComposePorts.isPlexImage("localhost:5000/linuxserver/plex"))
        #expect(ComposePorts.isPlexImage("plexinc/pms-docker"))
        #expect(!ComposePorts.isPlexImage("myduplex/app"))
        #expect(!ComposePorts.isPlexImage("complex/server"))
        let yaml = """
        services:
          x:
            image: myduplex/app
            network_mode: host
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: host network")
    }

    @Test func `non-plex host network stays rejected`() {
        let yaml = """
        services:
          x:
            image: alpine
            network_mode: host
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "192.168.8.10",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: host network")
    }

    @Test func `compose without published ports does not require a bind host`() throws {
        HostInfoService.lanBindIPv4Provider = { nil }
        defer { HostInfoService.lanBindIPv4Provider = nil }
        let yaml = """
        services:
          worker:
            image: alpine
            command: sleep 3600
        """
        let render = try ComposeAllowlist.render(
            yaml: yaml, workloadID: "worker-1", stateDir: stateDir,
        )
        #expect(render.publishedPorts.isEmpty)
        #expect(render.bindHost.isEmpty)
        #expect(render.yaml.contains("alpine"))
    }

    @Test func `wildcard bind host is accepted`() throws {
        let yaml = """
        services:
          x:
            image: alpine
            ports:
              - "8080:80"
        """
        let render = try ComposeAllowlist.render(
            yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "0.0.0.0",
        )
        #expect(render.bindHost == "0.0.0.0")
        #expect(render.publishedPorts.contains { $0.hostPort == 8_080 && $0.hostAddress == "0.0.0.0" })
    }

    @Test func `docker sock bind is rejected even through an allowlisted symlink`() throws {
        let dir = stateDir
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-sock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sock = tmp.appendingPathComponent("docker.sock")
        FileManager.default.createFile(atPath: sock.path, contents: Data())
        let alias = tmp.appendingPathComponent("evil")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sock)
        let yaml = """
        services:
          x:
            image: alpine
            volumes:
              - type: bind
                source: \(alias.path)
                target: /var/run/docker.sock
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml,
                workloadID: "id",
                stateDir: dir,
                bindHost: "192.168.8.10",
                allowedBinds: [alias.path],
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "unsupported compose feature: docker.sock")
    }

    @Test func `allowlisted host folder binds are rewritten`() throws {
        let dir = stateDir
        let media = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: media) }
        let yaml = """
        services:
          plex:
            image: lscr.io/linuxserver/plex
            volumes:
              - type: bind
                source: \(media.path)
                target: /movies
              - config:/config
        volumes:
          config:
        """
        let render = try ComposeAllowlist.render(
            yaml: yaml,
            workloadID: "plex-1",
            stateDir: dir,
            bindHost: "192.168.8.10",
            allowedBinds: [media.path],
        )
        #expect(render.yaml.contains(media.path))
        #expect(render.yaml.contains("/movies"))
        #expect(render.namedVolumes == ["config"])
    }
}
