import Foundation
import Testing
@testable import BarkVisorCore

struct ComposeResourceDeploymentTests {
    @Test func `hermes memory reservation survives catalog and runtime`() throws {
        let compose = """
        services:
          hermes:
            image: nousresearch/hermes-agent:v2026.9.14
            deploy:
              resources:
                limits:
                  cpus: '2.5'
                  memory: 2G
                reservations:
                  memory: 1G
        """
        let files = [
            "apps/hermes/app.json": Data(#"{"metadata":{"id":"hermes","name":"Hermes Agent"}}"#.utf8),
            "apps/hermes/docker-compose.yml": Data(compose.utf8),
        ]
        let entry = try #require(BigBearAppCatalog.parse(files: files).apps.first)
        #expect(entry.isInstallable)
        #expect(entry.compose.contains("reservations:"))
        let rendered = try ComposeAllowlist.render(
            yaml: entry.compose, workloadID: "hermes-resource-test",
            stateDir: URL(fileURLWithPath: "/tmp/hermes-resource-test"),
        )
        #expect(rendered.yaml.contains("1G"))
        #expect(rendered.yaml.contains("2G"))
        #expect(rendered.yaml.contains("2.5"))
    }

    @Test(arguments: [
        "replicas: 3",
        "resources:\n        reservations:\n          devices:\n            - capabilities: [gpu]",
        "resources:\n        limits:\n          memory: invalid",
        "resources:\n        limits:\n          cpus: '-1'",
    ])
    func `rejects unsupported deployment settings`(deploy: String) throws {
        let yaml = "services:\n  app:\n    image: example/app\n    deploy:\n      \(deploy)\n"
        #expect(throws: BarkVisorError.self) {
            try ComposeAllowlist.render(
                yaml: yaml, workloadID: "resource-test",
                stateDir: URL(fileURLWithPath: "/tmp/resource-test"),
            )
        }
        let files = [
            "apps/example/app.json": Data(#"{"metadata":{"id":"example","name":"Example"}}"#.utf8),
            "apps/example/docker-compose.yml": Data(yaml.utf8),
        ]
        let entry = try #require(BigBearAppCatalog.parse(files: files).apps.first)
        #expect(entry.unsupportedReasons.contains("deploy"))
    }
}
