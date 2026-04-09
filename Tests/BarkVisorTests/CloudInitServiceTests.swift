import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

final class CloudInitServiceTests: XCTestCase {
    // MARK: - SSH Key Validation

    func testValidSSHKeys() throws {
        XCTAssertNoThrow(
            try CloudInitService.validateSSHKey("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 user@host"),
        )
        XCTAssertNoThrow(
            try CloudInitService.validateSSHKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk user@host"),
        )
        XCTAssertNoThrow(
            try CloudInitService.validateSSHKey("ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI user@host"),
        )
        XCTAssertNoThrow(
            try CloudInitService.validateSSHKey("ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTI user@host"),
        )
        XCTAssertNoThrow(
            try CloudInitService.validateSSHKey("ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTI user@host"),
        )
        XCTAssertNoThrow(
            try CloudInitService.validateSSHKey("sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC user@host"),
        )
        XCTAssertNoThrow(
            try CloudInitService.validateSSHKey("sk-ecdsa-sha2-nistp256@openssh.com AAAAInNr user@host"),
        )
    }

    func testInvalidSSHKeyFormat() {
        XCTAssertThrowsError(try CloudInitService.validateSSHKey("not-a-key AAAA"))
        XCTAssertThrowsError(try CloudInitService.validateSSHKey("random garbage"))
        XCTAssertThrowsError(try CloudInitService.validateSSHKey("ssh-dsa AAAA")) // ssh-dss is valid, not ssh-dsa
    }

    func testSSHKeyWithNewlines() {
        XCTAssertThrowsError(try CloudInitService.validateSSHKey("ssh-rsa AAAA\ninjection"))
        XCTAssertThrowsError(try CloudInitService.validateSSHKey("ssh-rsa AAAA\rinjection"))
    }

    func testSSHKeyEmpty() throws {
        // Empty/whitespace keys pass validation (by design)
        XCTAssertNoThrow(try CloudInitService.validateSSHKey(""))
        XCTAssertNoThrow(try CloudInitService.validateSSHKey("   "))
    }

    func testSSHKeyWithControlCharacters() {
        XCTAssertThrowsError(try CloudInitService.validateSSHKey("ssh-rsa AAAA\u{00}injection"))
        XCTAssertThrowsError(try CloudInitService.validateSSHKey("ssh-rsa AAAA\u{07}bell"))
    }

    // MARK: - User Data Validation

    func testValidateUserDataValidYAML() throws {
        XCTAssertNoThrow(try CloudInitService.validateUserData("packages:\n  - vim\n  - curl\n"))
        XCTAssertNoThrow(try CloudInitService.validateUserData("runcmd:\n  - echo hello\n"))
        XCTAssertNoThrow(try CloudInitService.validateUserData(""))
    }

    func testValidateUserDataInvalidYAML() {
        // Unbalanced braces / bad indentation that Yams rejects
        XCTAssertThrowsError(try CloudInitService.validateUserData("key: [unclosed"))
        XCTAssertThrowsError(try CloudInitService.validateUserData(":\n  bad:\n bad"))
    }
}
