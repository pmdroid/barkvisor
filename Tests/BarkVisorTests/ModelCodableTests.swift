import Foundation
import Testing
@testable import BarkVisorCore

/// Additional model Codable tests beyond existing ModelCodingTests.
struct ModelCodableTests {
    // MARK: - CloudInitConfig

    @Test func `cloud init config codable`() throws {
        let config = CloudInitConfig(
            sshAuthorizedKeys: ["ssh-rsa AAAA key1"], userData: "packages:\n  - vim",
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CloudInitConfig.self, from: data)

        #expect(decoded.sshAuthorizedKeys == ["ssh-rsa AAAA key1"])
        #expect(decoded.userData == "packages:\n  - vim")
    }

    @Test func `cloud init config nil fields`() throws {
        let config = CloudInitConfig(sshAuthorizedKeys: nil, userData: nil)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CloudInitConfig.self, from: data)

        #expect(decoded.sshAuthorizedKeys == nil)
        #expect(decoded.userData == nil)
    }

    // MARK: - GuestUserDTO

    @Test func `guest user DTO codable`() throws {
        let user = GuestUserDTO(name: "alice", loginTime: 1_234_567_890.0)
        let data = try JSONEncoder().encode(user)
        let decoded = try JSONDecoder().decode(GuestUserDTO.self, from: data)

        #expect(decoded.name == "alice")
        #expect(decoded.loginTime == 1_234_567_890.0)
    }

    @Test func `guest user DTO nil login time`() throws {
        let user = GuestUserDTO(name: "bob", loginTime: nil)
        let data = try JSONEncoder().encode(user)
        let decoded = try JSONDecoder().decode(GuestUserDTO.self, from: data)

        #expect(decoded.name == "bob")
        #expect(decoded.loginTime == nil)
    }

    // MARK: - GuestFilesystemDTO

    @Test func `guest filesystem DTO codable`() throws {
        let fs = GuestFilesystemDTO(
            mountpoint: "/", type: "ext4", device: "/dev/vda1", totalBytes: 21_474_836_480,
            usedBytes: 5_368_709_120,
        )
        let data = try JSONEncoder().encode(fs)
        let decoded = try JSONDecoder().decode(GuestFilesystemDTO.self, from: data)

        #expect(decoded.mountpoint == "/")
        #expect(decoded.type == "ext4")
        #expect(decoded.totalBytes == 21_474_836_480)
        #expect(decoded.usedBytes == 5_368_709_120)
    }

    // MARK: - TemplateInput

    @Test func `template input codable`() throws {
        let input = TemplateInput(
            id: "hostname", label: "Hostname", type: "text",
            default: "myhost", required: true, placeholder: "Enter hostname",
            minLength: 1, maxLength: 64,
        )
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(TemplateInput.self, from: data)

        #expect(decoded.id == "hostname")
        #expect(decoded.label == "Hostname")
        #expect(decoded.type == "text")
        #expect(decoded.default == "myhost")
        #expect(decoded.required == true)
        #expect(decoded.minLength == 1)
        #expect(decoded.maxLength == 64)
    }

    @Test func `template input optional fields`() throws {
        let input = TemplateInput(
            id: "notes", label: "Notes", type: "textarea",
            default: nil, required: false, placeholder: nil,
            minLength: nil, maxLength: nil,
        )
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(TemplateInput.self, from: data)

        #expect(decoded.default == nil)
        #expect(decoded.required == false)
        #expect(decoded.placeholder == nil)
        #expect(decoded.minLength == nil)
        #expect(decoded.maxLength == nil)
    }

    // MARK: - TemplateCatalog

    @Test func `template catalog codable`() throws {
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

        #expect(decoded.version == 1)
        #expect(decoded.templates.count == 1)
        #expect(decoded.templates[0].slug == "ubuntu-server")
        #expect(decoded.templates[0].portForwards.count == 1)
        #expect(decoded.templates[0].portForwards[0].guestPort == 22)
    }

    // MARK: - MetricSample

    @Test func `metric sample codable`() throws {
        let sample = MetricSample(
            timestamp: "2025-01-01T00:00:00Z",
            cpuPercent: 45.5,
            memoryUsedMB: 2_048,
            diskReadBytes: 1_000_000,
            diskWriteBytes: 500_000,
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(MetricSample.self, from: data)

        #expect(decoded.timestamp == "2025-01-01T00:00:00Z")
        #expect(decoded.cpuPercent == 45.5)
        #expect(decoded.memoryUsedMB == 2_048)
        #expect(decoded.diskReadBytes == 1_000_000)
        #expect(decoded.diskWriteBytes == 500_000)
    }

    // MARK: - APIKeyResponse

    @Test func `api key response codable`() throws {
        let resp = APIKeyResponse(
            id: "k1", name: "Test", keyPrefix: "barkvisor_abcde",
            expiresAt: "2026-01-01T00:00:00Z", lastUsedAt: nil, createdAt: "2025-01-01T00:00:00Z",
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(APIKeyResponse.self, from: data)
        #expect(decoded.id == "k1")
        #expect(decoded.keyPrefix == "barkvisor_abcde")
        #expect(decoded.lastUsedAt == nil)
    }

    // MARK: - APIKeyCreateResponse

    @Test func `api key create response codable`() throws {
        let resp = APIKeyCreateResponse(
            id: "k1", name: "Test", key: "barkvisor_abc123",
            keyPrefix: "barkvisor_abc12", expiresAt: nil, createdAt: "2025-01-01T00:00:00Z",
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(APIKeyCreateResponse.self, from: data)
        #expect(decoded.key == "barkvisor_abc123")
    }

    // MARK: - UserPayload

    @Test func `user payload codable`() throws {
        let payload = UserPayload(
            sub: .init(value: "user-1"),
            username: "admin",
            exp: .init(value: Date().addingTimeInterval(3_600)),
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(UserPayload.self, from: data)
        #expect(decoded.sub.value == "user-1")
        #expect(decoded.username == "admin")
    }
}
