import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite struct CloudInitServiceTests {
    // MARK: - SSH Key Validation

    @Test func validSSHKeys() throws {
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTI user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTI user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC user@host") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("sk-ecdsa-sha2-nistp256@openssh.com AAAAInNr user@host") }
    }

    @Test func invalidSSHKeyFormat() {
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("not-a-key AAAA") }
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("random garbage") }
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-dsa AAAA") }
    }

    @Test func sshKeyWithNewlines() {
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-rsa AAAA\ninjection") }
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-rsa AAAA\rinjection") }
    }

    @Test func sshKeyEmpty() throws {
        // Empty/whitespace keys pass validation (by design)
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("") }
        #expect(throws: Never.self) { try CloudInitService.validateSSHKey("   ") }
    }

    @Test func sshKeyWithControlCharacters() {
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-rsa AAAA\u{00}injection") }
        #expect(throws: (any Error).self) { try CloudInitService.validateSSHKey("ssh-rsa AAAA\u{07}bell") }
    }

    // MARK: - User Data Validation

    @Test func validateUserDataValidYAML() throws {
        #expect(throws: Never.self) { try CloudInitService.validateUserData("packages:\n  - vim\n  - curl\n") }
        #expect(throws: Never.self) { try CloudInitService.validateUserData("runcmd:\n  - echo hello\n") }
        #expect(throws: Never.self) { try CloudInitService.validateUserData("") }
    }

    @Test func validateUserDataInvalidYAML() {
        #expect(throws: (any Error).self) { try CloudInitService.validateUserData("key: [unclosed") }
        #expect(throws: (any Error).self) { try CloudInitService.validateUserData(":\n  bad:\n bad") }
    }
}
