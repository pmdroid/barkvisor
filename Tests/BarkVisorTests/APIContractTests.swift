import Foundation
import Testing
import Yams
@testable import BarkVisor
@testable import BarkVisorCore

/// PAS-78: published OpenAPI matches the route inventory and decodes on
/// macOS + Linux CI without host-specific fixtures.
struct APIContractTests {
    private struct ErrorEnvelope: Codable, Equatable {
        var error: Bool
        var code: String
        var reason: String
        var status: Int
    }

    @Test func `contract version is 1 and matches agent info`() {
        #expect(APIContract.version == 1)
        #expect(APIContract.versionHeaderName == "X-BarkVisor-API-Version")
        let agent = AgentInfo(version: "test")
        #expect(agent.apiVersion == APIContract.version)
        #expect(APIContractSummary.current.apiVersion == APIContract.version)
        #expect(APIContractSummary.current.errorEnvelope == ["error", "code", "reason", "status"])
    }

    @Test func `published spec is loadable yaml`() throws {
        let yaml = try loadSpecYAML()
        #expect(yaml.contains("openapi:"))
        #expect(yaml.contains("X-BarkVisor-API-Version"))
        let root = try parseYAML(yaml)
        #expect(root["openapi"] as? String == "3.1.0")
        let info = try #require(root["info"] as? [String: Any])
        #expect(info["x-barkvisor-api-version"] as? Int == APIContract.version)
        #expect(info["x-barkvisor-version-header"] as? String == APIContract.versionHeaderName)

        let components = try #require(asStringKeyed(root["components"]))
        let schemas = try #require(asStringKeyed(components["schemas"]))
        let identity = try #require(asStringKeyed(schemas["AgentPeerIdentity"]))
        let identityProps = try #require(asStringKeyed(identity["properties"]))
        let listener = try #require(asStringKeyed(identityProps["listener"]))
        #expect(listener["enum"] as? [String] == ["mtls"])
        let list = try #require(asStringKeyed(schemas["HomeDeviceList"]))
        let listProps = try #require(asStringKeyed(list["properties"]))
        let devices = try #require(asStringKeyed(listProps["devices"]))
        #expect(devices["type"] as? String == "array")
        #expect(devices["enum"] == nil)
        let health = try #require(asStringKeyed(schemas["HomeDeviceHealthReport"]))
        let healthRequired = try #require(health["required"] as? [String])
        #expect(healthRequired == ["devices", "totals"])
    }

    @Test func `docs copy matches bundled spec`() throws {
        let bundled = try APIContract.specYAML()
        let docsURL = repoRoot().appendingPathComponent("docs/api/openapi.yaml")
        #expect(FileManager.default.fileExists(atPath: docsURL.path))
        let docs = try String(contentsOf: docsURL, encoding: .utf8)
        #expect(docs == bundled)
    }

    @Test func `docs workloadspec schema matches published file`() throws {
        let docsURL = repoRoot().appendingPathComponent("docs/api/workloadspec.schema.json")
        #expect(FileManager.default.fileExists(atPath: docsURL.path))
        let docs = try String(contentsOf: docsURL, encoding: .utf8)
        let object = try JSONSerialization.jsonObject(with: Data(docs.utf8)) as? [String: Any]
        #expect(object?["title"] as? String == "WorkloadSpec")
        #expect(object?["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
        if let bundled = try? APIContract.workloadSpecSchemaJSON() {
            #expect(docs == bundled)
        }
    }

    @Test func `openapi paths match route inventory`() throws {
        let yaml = try loadSpecYAML()
        let root = try parseYAML(yaml)
        let specPaths = Set(pathKeys(in: root))
        let inventory = Set(APIContract.routes.map(\.path))
        #expect(specPaths == inventory, "drift: spec-only=\(specPaths.subtracting(inventory)) inventory-only=\(inventory.subtracting(specPaths))")
    }

    @Test func `error envelope fixture decodes`() throws {
        let url = fixturesDir().appendingPathComponent("error-envelope.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ErrorEnvelope.self, from: data)
        #expect(decoded.error)
        #expect(decoded.code == "bad_request")
        #expect(decoded.reason == "Name is required")
        #expect(decoded.status == 400)

        let required = try schemaRequired(named: "ErrorEnvelope")
        #expect(Set(required) == Set(["error", "code", "reason", "status"]))
    }

    @Test func `vm fixture decodes required openapi fields`() throws {
        let cpu = min(2, max(1, PlatformHost.cpuCount))
        let vm = VM(
            id: "vm-fixture",
            name: "contract-vm",
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: cpu,
            memoryMb: 1_024,
            bootDiskId: "disk-1",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
        let encoded = try JSONEncoder().encode(VMResponse(from: vm))
        let decoded = try JSONDecoder().decode(VMResponse.self, from: encoded)
        #expect(decoded.id == "vm-fixture")
        #expect(decoded.spec.apiVersion == WorkloadSpec.currentAPIVersion)
        #expect(decoded.status.health == .stopped)
        #expect(decoded.cpuCount == cpu)
        try assertRequiredKeys(named: "VM", in: encoded)
    }

    @Test func `disk network image fixtures decode required fields`() throws {
        let disk = Disk(
            id: "disk-1",
            name: "boot",
            path: "/data/disks/disk-1.qcow2",
            sizeBytes: 1_073_741_824,
            format: "qcow2",
            vmId: nil,
            autoCreated: false,
            status: "ready",
            createdAt: "2026-01-01T00:00:00Z",
        )
        try assertRequiredKeys(named: "Disk", in: JSONEncoder().encode(disk))
        #expect(try JSONDecoder().decode(Disk.self, from: JSONEncoder().encode(disk)).id == "disk-1")

        let network = Network(
            id: "net-1",
            name: "default",
            mode: "nat",
            bridge: nil,
            macAddress: nil,
            dnsServer: nil,
            autoCreated: true,
            isDefault: true,
        )
        try assertRequiredKeys(named: "Network", in: JSONEncoder().encode(network))
        #expect(try JSONDecoder().decode(Network.self, from: JSONEncoder().encode(network)).mode == "nat")

        let image = ImageResponse(
            from: VMImage(
                id: "img-1",
                name: "Ubuntu",
                imageType: "cloud-image",
                arch: "arm64",
                path: "/data/images/img-1.qcow2",
                sizeBytes: 1_073_741_824,
                status: "ready",
                error: nil,
                sourceUrl: "https://example.invalid/ubuntu.qcow2",
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
            ),
        )
        let imageData = try JSONEncoder().encode(image)
        try assertRequiredKeys(named: "Image", in: imageData)
        #expect(try JSONDecoder().decode(ImageResponse.self, from: imageData).arch == "arm64")
    }

    @Test func `reserved prefixes stay unimplemented in this spec`() throws {
        let yaml = try loadSpecYAML()
        let root = try parseYAML(yaml)
        let specPaths = pathKeys(in: root)
        for item in APIContract.reservedPrefixes {
            #expect(!specPaths.contains(where: { $0.hasPrefix(item.prefix) }))
        }
        #expect(APIContractSummary.current.reserved["evolving"]?.contains("/api/apps") == true)
        #expect(APIContract.routes.contains { $0.path == "/api/home/devices" })
        #expect(APIContract.routes.contains { $0.path == "/api/home/devices/health" })
        #expect(APIContract.routes.contains { $0.path == "/api/home/placement/score" })
        #expect(APIContract.routes.contains { $0.path == "/api/home/devices/{id}/v1/{path}" })
    }

    @Test func `sse and websocket routes are marked out of band`() throws {
        let oob = Set(APIContract.routes(stability: .outOfBand).map(\.path))
        #expect(oob.contains("/api/vms/{id}/state"))
        #expect(oob.contains("/api/vms/{id}/console"))
        #expect(oob.contains("/api/vms/{id}/vnc"))
        #expect(oob.contains("/api/home/devices/{id}/v1/vms/{vmId}/console"))
        #expect(oob.contains("/api/home/devices/{id}/v1/vms/{vmId}/vnc"))
        #expect(oob.contains("/api/auth/ws-ticket"))

        let yaml = try loadSpecYAML()
        #expect(yaml.contains("x-barkvisor-transport: sse"))
        #expect(yaml.contains("x-barkvisor-transport: websocket"))
    }

    // MARK: - Helpers

    private func loadSpecYAML() throws -> String {
        if let bundled = try? APIContract.specYAML() {
            return bundled
        }
        return try String(
            contentsOf: repoRoot().appendingPathComponent("docs/api/openapi.yaml"),
            encoding: .utf8,
        )
    }

    private func parseYAML(_ yaml: String) throws -> [String: Any] {
        let loaded = try Yams.load(yaml: yaml)
        return try #require(asStringKeyed(loaded))
    }

    private func pathKeys(in root: [String: Any]) -> [String] {
        guard let paths = asStringKeyed(root["paths"]) else { return [] }
        return Array(paths.keys)
    }

    private func asStringKeyed(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let dict = value as? [AnyHashable: Any] else { return nil }
        var out: [String: Any] = [:]
        for (key, nested) in dict {
            out[String(describing: key)] = nested
        }
        return out
    }

    private func assertRequiredKeys(named name: String, in data: Data) throws {
        let dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in try schemaRequired(named: name) {
            #expect(dict[key] != nil, "\(name) JSON missing required OpenAPI property \(key)")
        }
    }

    private func schemaRequired(named name: String) throws -> [String] {
        let yaml = try loadSpecYAML()
        let root = try parseYAML(yaml)
        let components = try #require(asStringKeyed(root["components"]))
        let schemas = try #require(asStringKeyed(components["schemas"]))
        let schema = try #require(asStringKeyed(schemas[name]))
        if let required = schema["required"] as? [String] {
            return required
        }
        if let required = schema["required"] as? [Any] {
            return required.map { String(describing: $0) }
        }
        Issue.record("schema \(name) has no required list")
        return []
    }

    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/api")
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        Issue.record("could not find Package.swift from \(#filePath)")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
