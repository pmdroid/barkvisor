import XCTest
@testable import BarkVisorCore

final class TemplateRendererTests: XCTestCase {
    // MARK: - Basic placeholder replacement

    func testSimplePlaceholderReplacement() throws {
        let template = "hostname: {{hostname}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["hostname": "myhost"])
        XCTAssertEqual(result, "hostname: myhost")
    }

    func testMultiplePlaceholders() throws {
        let template = "user: {{username}} host: {{hostname}}"
        let result = try TemplateRenderer.render(
            template: template, inputs: ["username": "admin", "hostname": "srv1"],
        )
        XCTAssertEqual(result, "user: admin host: srv1")
    }

    func testEmptyTemplateReturnsEmpty() throws {
        let result = try TemplateRenderer.render(template: "", inputs: ["key": "value"])
        XCTAssertEqual(result, "")
    }

    // MARK: - password_hash

    func testPasswordHashGeneration() throws {
        let template = "password: {{password_hash}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["password": "secret123"])
        XCTAssertTrue(result.contains("$6$"), "Should contain SHA-512 crypt prefix: \(result)")
        XCTAssertFalse(result.contains("{{password_hash}}"), "Placeholder should be replaced")
    }

    // MARK: - ssh_keys_yaml

    func testSSHKeysYAMLGeneration() throws {
        let template = "ssh_authorized_keys:\n{{ssh_keys_yaml}}"
        let keys = "ssh-rsa AAAA key1\nssh-ed25519 BBBB key2"
        let result = try TemplateRenderer.render(template: template, inputs: ["ssh_keys": keys])
        XCTAssertTrue(result.contains("      - ssh-rsa AAAA key1"))
        XCTAssertTrue(result.contains("      - ssh-ed25519 BBBB key2"))
    }

    func testSSHKeysYAMLEmpty() throws {
        let template = "keys: {{ssh_keys_yaml}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["ssh_keys": ""])
        XCTAssertEqual(result, "keys: ")
    }

    // MARK: - extra_packages_yaml

    func testExtraPackagesYAML() throws {
        let template = "packages:\n{{extra_packages_yaml}}"
        let result = try TemplateRenderer.render(
            template: template, inputs: ["extra_packages": "vim curl htop"],
        )
        XCTAssertTrue(result.contains("  - vim"))
        XCTAssertTrue(result.contains("  - curl"))
        XCTAssertTrue(result.contains("  - htop"))
    }

    func testExtraPackagesEmpty() throws {
        let template = "packages: {{extra_packages_yaml}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["extra_packages": ""])
        XCTAssertEqual(result, "packages: ")
    }

    // MARK: - YAML escaping

    func testYAMLEscapingDangerousChars() throws {
        let template = "value: {{input}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["input": "hello: world"])
        XCTAssertTrue(result.contains("'hello: world'"), "Should be YAML single-quoted: \(result)")
    }

    func testYAMLEscapingSingleQuotes() throws {
        let template = "value: {{input}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["input": "it's"])
        // YAML single-quote escaping doubles the quote
        XCTAssertTrue(result.contains("'it''s'"), "Should escape single quotes: \(result)")
    }

    func testSafeValueNotQuoted() throws {
        let template = "value: {{input}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["input": "simple"])
        XCTAssertEqual(result, "value: simple")
    }

    // MARK: - SHA-512 Crypt

    func testSHA512CryptDeterministic() {
        let hash1 = TemplateRenderer.sha512Crypt(password: "test", salt: "abcdefgh", rounds: 5_000)
        let hash2 = TemplateRenderer.sha512Crypt(password: "test", salt: "abcdefgh", rounds: 5_000)
        XCTAssertEqual(hash1, hash2, "Same password + salt should produce same hash")
    }

    func testSHA512CryptFormat() {
        let hash = TemplateRenderer.sha512Crypt(password: "password", salt: "testsalt", rounds: 5_000)
        XCTAssertTrue(hash.hasPrefix("$6$testsalt$"), "Should have $6$salt$ format: \(hash)")
    }

    func testSHA512CryptCustomRounds() {
        let hash = TemplateRenderer.sha512Crypt(password: "password", salt: "salt1234", rounds: 1_000)
        XCTAssertTrue(
            hash.hasPrefix("$6$rounds=1000$salt1234$"), "Custom rounds should appear: \(hash)",
        )
    }

    func testSHA512CryptDifferentPasswordsDifferentHashes() {
        let hash1 = TemplateRenderer.sha512Crypt(
            password: "password1", salt: "same_salt", rounds: 5_000,
        )
        let hash2 = TemplateRenderer.sha512Crypt(
            password: "password2", salt: "same_salt", rounds: 5_000,
        )
        XCTAssertNotEqual(hash1, hash2)
    }

    func testSHA512CryptDifferentSaltsDifferentHashes() {
        let hash1 = TemplateRenderer.sha512Crypt(
            password: "same_password", salt: "salt1111", rounds: 5_000,
        )
        let hash2 = TemplateRenderer.sha512Crypt(
            password: "same_password", salt: "salt2222", rounds: 5_000,
        )
        XCTAssertNotEqual(hash1, hash2)
    }

    func testGenerateSHA512CryptRandomSalt() {
        let hash1 = TemplateRenderer.generateSHA512Crypt(password: "test")
        let hash2 = TemplateRenderer.generateSHA512Crypt(password: "test")
        XCTAssertNotEqual(hash1, hash2, "Random salts should produce different hashes")
        XCTAssertTrue(hash1.hasPrefix("$6$"))
        XCTAssertTrue(hash2.hasPrefix("$6$"))
    }
}
