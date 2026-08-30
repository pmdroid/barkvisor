import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct CloudInitServiceTests {
    // MARK: - SSH Key Validation

    @Test func `valid SSH keys`() throws {
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTI user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTI user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("sk-ecdsa-sha2-nistp256@openssh.com AAAAInNr user@host") }
    }

    @Test func `invalid SSH key format`() {
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("not-a-key AAAA") }
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("random garbage") }
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-dsa AAAA") }
    }

    @Test func `ssh key with newlines`() {
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-rsa AAAA\ninjection") }
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-rsa AAAA\rinjection") }
    }

    @Test func `ssh key empty`() throws {
        // Empty/whitespace keys pass validation (by design)
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("   ") }
    }

    @Test func `ssh key with control characters`() {
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-rsa AAAA\u{00}injection") }
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-rsa AAAA\u{07}bell") }
    }

    // MARK: - User Data Validation

    @Test func `validate user data valid YAML`() throws {
        #expect(throws: Never.self) { try CloudInitService.validateUserData("packages:\n  - vim\n  - curl\n") }
        #expect(throws: Never.self) { try CloudInitService.validateUserData("runcmd:\n  - echo hello\n") }
        #expect(throws: Never.self) { try CloudInitService.validateUserData("") }
    }

    @Test func `validate user data invalid YAML`() {
        #expect(throws: (any Error).self) { try CloudInitService.validateUserData("key: [unclosed") }
        #expect(throws: (any Error).self) { try CloudInitService.validateUserData(":\n  bad:\n bad") }
    }

    @Test func `wizard user data rejects identity keys`() {
        #expect(throws: (any Error).self) {
            try CloudInitService.validateUserData("users:\n  - name: ubuntu\n")
        }
        #expect(throws: (any Error).self) {
            try CloudInitService.validateUserData("ssh_authorized_keys:\n  - ssh-ed25519 AAAA\n")
        }
    }

    @Test func `catalog user data allows identity keys`() throws {
        try CloudInitService.validateUserData(
            "users:\n  - name: ubuntu\n    ssh_authorized_keys:\n      - ssh-ed25519 AAAA\n",
            allowCatalogIdentityKeys: true,
        )
    }

    // MARK: - userDataRef confinement

    @Test func `userDataRef accepts current path without change`() throws {
        try CloudInitService.validateUserDataRef(
            "/data/cidata.iso",
            vmID: "vm-1",
            current: "/data/cidata.iso",
        )
    }

    @Test func `userDataRef accepts service-generated ISO`() throws {
        let generated = CloudInitService.generatedISOURL(vmID: "vm-1").path
        try CloudInitService.validateUserDataRef(generated, vmID: "vm-1")
    }

    @Test func `sshAuthorizedKeys reads stored cloud-config`() {
        let keys = CloudInitService.sshAuthorizedKeys(
            from: """
            #cloud-config
            ssh_authorized_keys:
              - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk user@host
              - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 other@host
            packages:
              - vim
            """,
        )
        #expect(keys.count == 2)
        #expect(keys[0].hasPrefix("ssh-ed25519"))
        #expect(CloudInitService.sshAuthorizedKeys(from: nil).isEmpty)
        #expect(CloudInitService.sshAuthorizedKeys(from: "packages:\n  - vim\n").isEmpty)
    }

    @Test func `userDataRef rejects host files and other VMs`() {
        let other = CloudInitService.generatedISOURL(vmID: "vm-2").path
        #expect(throws: BarkVisorError.self) {
            try CloudInitService.validateUserDataRef("/etc/passwd", vmID: "vm-1")
        }
        #expect(throws: BarkVisorError.self) {
            try CloudInitService.validateUserDataRef(other, vmID: "vm-1")
        }
        #expect(throws: BarkVisorError.self) {
            try CloudInitService.validateUserDataRef("", vmID: "vm-1")
        }
    }

    @Test func `userDataRef rejects path traversal out of generated ISO`() {
        let generated = CloudInitService.generatedISOURL(vmID: "vm-1")
        let escaped = generated.deletingLastPathComponent()
            .appendingPathComponent("..")
            .appendingPathComponent("..")
            .appendingPathComponent("etc")
            .appendingPathComponent("passwd")
            .path
        #expect(throws: BarkVisorError.self) {
            try CloudInitService.validateUserDataRef(escaped, vmID: "vm-1")
        }
    }

    @Test func `hostnameFromVMName slugifies display names`() {
        #expect(hostnameFromVMName("Ubuntu Server") == "ubuntu-server")
        #expect(hostnameFromVMName("  Pi-hole  ") == "pi-hole")
        #expect(hostnameFromVMName("My---VM") == "my-vm")
    }

    @Test func `generateISO meta-data uses hostname slug`() throws {
        let vmID = "vm-hostname-test"
        do {
            _ = try CloudInitService.generateISO(
                vmID: vmID,
                vmName: "Ubuntu Server",
                sshKeys: [],
                userData: nil,
            )
        } catch BarkVisorError.cloudInitFailed {}
        let dir = CloudInitService.generatedISOURL(vmID: vmID).deletingLastPathComponent()
        let meta = try String(
            contentsOf: dir.appendingPathComponent("meta-data"),
            encoding: .utf8,
        )
        #expect(meta.contains("local-hostname: ubuntu-server"))
        let userData = try String(
            contentsOf: dir.appendingPathComponent("user-data"),
            encoding: .utf8,
        )
        #expect(userData.contains("hostname: ubuntu-server"))
        #expect(CloudInitService.storedNetworkConfig(vmID: vmID) == nil)
    }
}
