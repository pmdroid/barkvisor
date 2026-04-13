import Foundation
import Testing
@testable import BarkVisorCore

@Suite struct TemplateRendererTests {
    // MARK: - Basic placeholder replacement

    @Test func simplePlaceholderReplacement() throws {
        let template = "hostname: {{hostname}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["hostname": "myhost"])
        #expect(result == "hostname: myhost")
    }

    @Test func multiplePlaceholders() throws {
        let template = "user: {{username}} host: {{hostname}}"
        let result = try TemplateRenderer.render(
            template: template, inputs: ["username": "admin", "hostname": "srv1"],
        )
        #expect(result == "user: admin host: srv1")
    }

    @Test func emptyTemplateReturnsEmpty() throws {
        let result = try TemplateRenderer.render(template: "", inputs: ["key": "value"])
        #expect(result == "")
    }

    // MARK: - password_hash

    @Test func passwordHashGeneration() throws {
        let template = "password: {{password_hash}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["password": "secret123"])
        #expect(result.contains("$6$"), "Should contain SHA-512 crypt prefix: \(result)")
        #expect(!result.contains("{{password_hash}}"), "Placeholder should be replaced")
    }

    // MARK: - ssh_keys_yaml

    @Test func sshKeysYAMLGeneration() throws {
        let template = "ssh_authorized_keys:\n{{ssh_keys_yaml}}"
        let keys = "ssh-rsa AAAA key1\nssh-ed25519 BBBB key2"
        let result = try TemplateRenderer.render(template: template, inputs: ["ssh_keys": keys])
        #expect(result.contains("      - ssh-rsa AAAA key1"))
        #expect(result.contains("      - ssh-ed25519 BBBB key2"))
    }

    @Test func sshKeysYAMLEmpty() throws {
        let template = "keys: {{ssh_keys_yaml}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["ssh_keys": ""])
        #expect(result == "keys: ")
    }

    // MARK: - extra_packages_yaml

    @Test func extraPackagesYAML() throws {
        let template = "packages:\n{{extra_packages_yaml}}"
        let result = try TemplateRenderer.render(
            template: template, inputs: ["extra_packages": "vim curl htop"],
        )
        #expect(result.contains("  - vim"))
        #expect(result.contains("  - curl"))
        #expect(result.contains("  - htop"))
    }

    @Test func extraPackagesEmpty() throws {
        let template = "packages: {{extra_packages_yaml}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["extra_packages": ""])
        #expect(result == "packages: ")
    }

    // MARK: - YAML escaping

    @Test func yamlEscapingDangerousChars() throws {
        let template = "value: {{input}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["input": "hello: world"])
        #expect(result.contains("'hello: world'"), "Should be YAML single-quoted: \(result)")
    }

    @Test func yamlEscapingSingleQuotes() throws {
        let template = "value: {{input}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["input": "it's"])
        // YAML single-quote escaping doubles the quote
        #expect(result.contains("'it''s'"), "Should escape single quotes: \(result)")
    }

    @Test func safeValueNotQuoted() throws {
        let template = "value: {{input}}"
        let result = try TemplateRenderer.render(template: template, inputs: ["input": "simple"])
        #expect(result == "value: simple")
    }

    // MARK: - SHA-512 Crypt

    @Test func sha512CryptDeterministic() {
        let hash1 = TemplateRenderer.sha512Crypt(password: "test", salt: "abcdefgh", rounds: 5_000)
        let hash2 = TemplateRenderer.sha512Crypt(password: "test", salt: "abcdefgh", rounds: 5_000)
        #expect(hash1 == hash2, "Same password + salt should produce same hash")
    }

    @Test func sha512CryptFormat() {
        let hash = TemplateRenderer.sha512Crypt(password: "password", salt: "testsalt", rounds: 5_000)
        #expect(hash.hasPrefix("$6$testsalt$"), "Should have $6$salt$ format: \(hash)")
    }

    @Test func sha512CryptCustomRounds() {
        let hash = TemplateRenderer.sha512Crypt(password: "password", salt: "salt1234", rounds: 1_000)
        #expect(
            hash.hasPrefix("$6$rounds=1000$salt1234$"), "Custom rounds should appear: \(hash)",
        )
    }

    @Test func sha512CryptDifferentPasswordsDifferentHashes() {
        let hash1 = TemplateRenderer.sha512Crypt(
            password: "password1", salt: "same_salt", rounds: 5_000,
        )
        let hash2 = TemplateRenderer.sha512Crypt(
            password: "password2", salt: "same_salt", rounds: 5_000,
        )
        #expect(hash1 != hash2)
    }

    @Test func sha512CryptDifferentSaltsDifferentHashes() {
        let hash1 = TemplateRenderer.sha512Crypt(
            password: "same_password", salt: "salt1111", rounds: 5_000,
        )
        let hash2 = TemplateRenderer.sha512Crypt(
            password: "same_password", salt: "salt2222", rounds: 5_000,
        )
        #expect(hash1 != hash2)
    }

    @Test func generateSHA512CryptRandomSalt() {
        let hash1 = TemplateRenderer.generateSHA512Crypt(password: "test")
        let hash2 = TemplateRenderer.generateSHA512Crypt(password: "test")
        #expect(hash1 != hash2, "Random salts should produce different hashes")
        #expect(hash1.hasPrefix("$6$"))
        #expect(hash2.hasPrefix("$6$"))
    }
}
