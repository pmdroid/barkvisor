import Foundation
import Testing
@testable import BarkVisorCore

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
        #expect(render.bindHost == "192.168.8.10")
        #expect(render.yaml.contains("192.168.8.10"))
        #expect(render.yaml.contains("host_ip"))
        #expect(!render.yaml.contains("0.0.0.0"))
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

    @Test func `published ports bind the LAN address including UDP`() throws {
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
                && $0.hostAddress == "192.168.8.10"
        })
        #expect(render.publishedPorts.contains {
            $0.hostPort == 1_900 && $0.proto == "udp" && $0.hostAddress == "192.168.8.10"
        })
        #expect(render.publishedPorts.contains {
            $0.hostPort == 5_353 && $0.proto == "udp" && $0.hostAddress == "192.168.8.10"
        })
        #expect(
            render.yaml.contains("host_ip: 192.168.8.10")
                || render.yaml.contains("host_ip: '192.168.8.10'")
                || render.yaml.contains("host_ip: \"192.168.8.10\""),
        )
        #expect(!render.yaml.contains("0.0.0.0"))
        #expect(!render.yaml.contains("::"))
        let rules = ApplicationLifecycleService.portRules(render.publishedPorts)
        try PortRegistry.assertUnique(rules)
        #expect(rules.contains { $0.hostPort == 1_900 && $0.protocol == "udp" })
        #expect(rules.contains { $0.hostPort == 8_096 && $0.protocol == "tcp" })
    }

    @Test func `plex host network is rewritten to LAN 32400`() throws {
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
                && $0.hostAddress == "192.168.8.10"
        })
        #expect(render.yaml.contains("32400"))
        #expect(render.yaml.contains("192.168.8.10"))
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

    @Test func `wildcard bind host is rejected`() {
        let yaml = """
        services:
          x:
            image: alpine
            ports:
              - "8080:80"
        """
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml, workloadID: "id", stateDir: stateDir, bindHost: "0.0.0.0",
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "No LAN address to bind published ports")
    }
}
