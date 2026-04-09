import XCTest
@testable import BarkVisorCore

/// Additional model Codable tests beyond existing ModelCodingTests.
final class ModelCodableTests: XCTestCase {
    // MARK: - CloudInitConfig

    func testCloudInitConfigCodable() throws {
        let config = CloudInitConfig(
            sshAuthorizedKeys: ["ssh-rsa AAAA key1"], userData: "packages:\n  - vim",
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CloudInitConfig.self, from: data)

        XCTAssertEqual(decoded.sshAuthorizedKeys, ["ssh-rsa AAAA key1"])
        XCTAssertEqual(decoded.userData, "packages:\n  - vim")
    }

    func testCloudInitConfigNilFields() throws {
        let config = CloudInitConfig(sshAuthorizedKeys: nil, userData: nil)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CloudInitConfig.self, from: data)

        XCTAssertNil(decoded.sshAuthorizedKeys)
        XCTAssertNil(decoded.userData)
    }

    // MARK: - GuestUserDTO

    func testGuestUserDTOCodable() throws {
        let user = GuestUserDTO(name: "alice", loginTime: 1_234_567_890.0)
        let data = try JSONEncoder().encode(user)
        let decoded = try JSONDecoder().decode(GuestUserDTO.self, from: data)

        XCTAssertEqual(decoded.name, "alice")
        XCTAssertEqual(decoded.loginTime, 1_234_567_890.0)
    }

    func testGuestUserDTONilLoginTime() throws {
        let user = GuestUserDTO(name: "bob", loginTime: nil)
        let data = try JSONEncoder().encode(user)
        let decoded = try JSONDecoder().decode(GuestUserDTO.self, from: data)

        XCTAssertEqual(decoded.name, "bob")
        XCTAssertNil(decoded.loginTime)
    }

    // MARK: - GuestFilesystemDTO

    func testGuestFilesystemDTOCodable() throws {
        let fs = GuestFilesystemDTO(
            mountpoint: "/", type: "ext4", device: "/dev/vda1", totalBytes: 21_474_836_480,
            usedBytes: 5_368_709_120,
        )
        let data = try JSONEncoder().encode(fs)
        let decoded = try JSONDecoder().decode(GuestFilesystemDTO.self, from: data)

        XCTAssertEqual(decoded.mountpoint, "/")
        XCTAssertEqual(decoded.type, "ext4")
        XCTAssertEqual(decoded.totalBytes, 21_474_836_480)
        XCTAssertEqual(decoded.usedBytes, 5_368_709_120)
    }

    // MARK: - TemplateInput

    func testTemplateInputCodable() throws {
        let input = TemplateInput(
            id: "hostname", label: "Hostname", type: "text",
            default: "myhost", required: true, placeholder: "Enter hostname",
            minLength: 1, maxLength: 64,
        )
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(TemplateInput.self, from: data)

        XCTAssertEqual(decoded.id, "hostname")
        XCTAssertEqual(decoded.label, "Hostname")
        XCTAssertEqual(decoded.type, "text")
        XCTAssertEqual(decoded.default, "myhost")
        XCTAssertEqual(decoded.required, true)
        XCTAssertEqual(decoded.minLength, 1)
        XCTAssertEqual(decoded.maxLength, 64)
    }

    func testTemplateInputOptionalFields() throws {
        let input = TemplateInput(
            id: "notes", label: "Notes", type: "textarea",
            default: nil, required: false, placeholder: nil,
            minLength: nil, maxLength: nil,
        )
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(TemplateInput.self, from: data)

        XCTAssertNil(decoded.default)
        XCTAssertFalse(decoded.required)
        XCTAssertNil(decoded.placeholder)
        XCTAssertNil(decoded.minLength)
        XCTAssertNil(decoded.maxLength)
    }

    // MARK: - TemplateCatalog

    func testTemplateCatalogCodable() throws {
        let entry = TemplateCatalogEntry(
            slug: "ubuntu-server", name: "Ubuntu Server",
            description: "Server template", category: "server", icon: "ubuntu",
            imageSlug: "ubuntu-24.04", cpuCount: 4, memoryMB: 4_096, diskSizeGB: 20,
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 2_222, guestPort: 22)],
            networkMode: "nat",
            inputs: [
                TemplateInput(
                    id: "hostname",
                    label: "Hostname",
                    type: "text",
                    default: nil,
                    required: true,
                    placeholder: nil,
                    minLength: nil,
                    maxLength: nil,
                ),
            ],
            userDataTemplate: "#cloud-config\nhostname: {{hostname}}",
        )
        let catalog = TemplateCatalog(version: 1, templates: [entry])

        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(TemplateCatalog.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.templates.count, 1)
        XCTAssertEqual(decoded.templates[0].slug, "ubuntu-server")
        XCTAssertEqual(decoded.templates[0].portForwards.count, 1)
        XCTAssertEqual(decoded.templates[0].portForwards[0].guestPort, 22)
    }

    // MARK: - MetricSample

    func testMetricSampleCodable() throws {
        let sample = MetricSample(
            timestamp: "2025-01-01T00:00:00Z",
            cpuPercent: 45.5,
            memoryUsedMB: 2_048,
            diskReadBytes: 1_000_000,
            diskWriteBytes: 500_000,
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(MetricSample.self, from: data)

        XCTAssertEqual(decoded.timestamp, "2025-01-01T00:00:00Z")
        XCTAssertEqual(decoded.cpuPercent, 45.5)
        XCTAssertEqual(decoded.memoryUsedMB, 2_048)
        XCTAssertEqual(decoded.diskReadBytes, 1_000_000)
        XCTAssertEqual(decoded.diskWriteBytes, 500_000)
    }

    // MARK: - APIKeyResponse

    func testAPIKeyResponseCodable() throws {
        let resp = APIKeyResponse(
            id: "k1", name: "Test", keyPrefix: "barkvisor_abcde",
            expiresAt: "2026-01-01T00:00:00Z", lastUsedAt: nil, createdAt: "2025-01-01T00:00:00Z",
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(APIKeyResponse.self, from: data)
        XCTAssertEqual(decoded.id, "k1")
        XCTAssertEqual(decoded.keyPrefix, "barkvisor_abcde")
        XCTAssertNil(decoded.lastUsedAt)
    }

    // MARK: - APIKeyCreateResponse

    func testAPIKeyCreateResponseCodable() throws {
        let resp = APIKeyCreateResponse(
            id: "k1", name: "Test", key: "barkvisor_abc123",
            keyPrefix: "barkvisor_abc12", expiresAt: nil, createdAt: "2025-01-01T00:00:00Z",
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(APIKeyCreateResponse.self, from: data)
        XCTAssertEqual(decoded.key, "barkvisor_abc123")
    }

    // MARK: - UserPayload

    func testUserPayloadCodable() throws {
        let payload = UserPayload(
            sub: .init(value: "user-1"),
            username: "admin",
            exp: .init(value: Date().addingTimeInterval(3_600)),
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(UserPayload.self, from: data)
        XCTAssertEqual(decoded.sub.value, "user-1")
        XCTAssertEqual(decoded.username, "admin")
    }
}
