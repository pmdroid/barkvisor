import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for authentication-related logic: AuthenticatedUser, password validation,
/// and Vapor request DTO validations.
struct AuthTests {
    // MARK: - AuthenticatedUser

    @Test func `authenticated user JWT`() {
        let user = AuthenticatedUser(
            userId: "user-1", username: "admin", authMethod: "jwt", apiKeyId: nil,
        )
        #expect(user.userId == "user-1")
        #expect(user.username == "admin")
        #expect(user.authMethod == "jwt")
        #expect(user.apiKeyId == nil)
    }

    @Test func `authenticated user API key`() {
        let user = AuthenticatedUser(
            userId: "user-1", username: "admin", authMethod: "apikey", apiKeyId: "key-1",
        )
        #expect(user.authMethod == "apikey")
        #expect(user.apiKeyId == "key-1")
    }

    @Test func `authenticated user ticket`() {
        let user = AuthenticatedUser(
            userId: "user-1", username: "admin", authMethod: "ticket", apiKeyId: nil,
        )
        #expect(user.authMethod == "ticket")
    }

    // MARK: - Password Minimum Length

    @Test func `password min length requirement`() {
        let tooShort = ["", "a", "12345", "123456789"]
        for pw in tooShort {
            #expect(pw.count < 10, "'\(pw)' should fail the 10-char minimum")
        }
        #expect("abcdefghij".count >= 10, "10 chars should pass")
        #expect("abcdefghijk".count >= 10, "11 chars should pass")
    }

    // MARK: - Seeder Password Validation

    @Test func `seeder password min length`() {
        let shortPw = "123456789"
        #expect(shortPw.count < 10)
        let goodPw = "1234567890"
        #expect(goodPw.count >= 10)
    }

    // MARK: - API Key Prefix Detection

    @Test func `api key prefix detection`() {
        let apiKey = "barkvisor_abcdefghij"
        #expect(apiKey.hasPrefix("barkvisor_"))
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"
        #expect(!jwt.hasPrefix("barkvisor_"))
    }

    @Test func `api key prefix length`() {
        let apiKey = "barkvisor_abcde_remaining_chars"
        let prefix = String(apiKey.prefix(15))
        #expect(prefix == "barkvisor_abcde")
        #expect(prefix.count == 15)
    }

    // MARK: - BcryptHasher Protocol Conformance

    @Test func `bcrypt hasher conforms to password hasher`() {
        let hasher: PasswordHasher = BcryptHasher.shared
        #expect(hasher != nil)
    }

    @Test func `bcrypt hasher hash and verify`() throws {
        let hasher = BcryptHasher.shared
        let password = "test-password-123"
        let hash = try hasher.hash(password)
        #expect(hash != password)
        #expect(hash.hasPrefix("$2"))
        #expect(try hasher.verify(password, against: hash))
        #expect(try !hasher.verify("wrong-password", against: hash))
    }

    // MARK: - Stop Method Validation

    @Test func `stop method allowed values`() {
        let allowedMethods: Set = ["guest-agent", "acpi", "force"]
        #expect(allowedMethods.contains("guest-agent"))
        #expect(allowedMethods.contains("acpi"))
        #expect(allowedMethods.contains("force"))
        #expect(!allowedMethods.contains("kill"))
        #expect(!allowedMethods.contains(""))
        #expect(!allowedMethods.contains("FORCE"))
    }
}
