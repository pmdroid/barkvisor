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
        let render = try ComposeAllowlist.render(yaml: yaml, workloadID: "abc-123", stateDir: dir)
        #expect(render.publishedPorts.contains { $0.hostPort == 8_080 && $0.containerPort == 80 })
        #expect(render.namedVolumes == ["data"])
        #expect(render.yaml.contains("barkvisor.workload"))
        #expect(render.yaml.contains("abc-123"))
        #expect(render.yaml.contains("bv-abc-123-whoami"))
        #expect(render.yaml.contains("\(dir.path)/volumes/data"))
        #expect(!render.yaml.contains("privileged"))
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
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
            _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: dir)
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
                _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
            }
            guard case let .badRequest(message) = error else {
                Issue.record("expected badRequest")
                continue
            }
            #expect(message == "unsupported compose feature: bind")
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
                _ = try ComposeAllowlist.render(yaml: yaml, workloadID: "id", stateDir: stateDir)
            }
            guard case let .badRequest(message) = error else { continue }
            #expect(message.hasPrefix("unsupported compose feature:"))
        }
    }
}
