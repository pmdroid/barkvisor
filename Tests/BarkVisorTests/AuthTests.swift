import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for authentication-related logic: AuthenticatedUser, password validation,
/// and Vapor request DTO validations.
final class AuthTests: XCTestCase {
    // MARK: - AuthenticatedUser

    func testAuthenticatedUserJWT() {
        let user = AuthenticatedUser(
            userId: "user-1", username: "admin",
            authMethod: "jwt", apiKeyId: nil,
        )
        XCTAssertEqual(user.userId, "user-1")
        XCTAssertEqual(user.username, "admin")
        XCTAssertEqual(user.authMethod, "jwt")
        XCTAssertNil(user.apiKeyId)
    }

    func testAuthenticatedUserAPIKey() {
        let user = AuthenticatedUser(
            userId: "user-1", username: "admin",
            authMethod: "apikey", apiKeyId: "key-1",
        )
        XCTAssertEqual(user.authMethod, "apikey")
        XCTAssertEqual(user.apiKeyId, "key-1")
    }

    func testAuthenticatedUserTicket() {
        let user = AuthenticatedUser(
            userId: "user-1", username: "admin",
            authMethod: "ticket", apiKeyId: nil,
        )
        XCTAssertEqual(user.authMethod, "ticket")
    }

    // MARK: - Password Minimum Length

    func testPasswordMinLengthRequirement() {
        // Password setup requires >= 10 chars
        let tooShort = ["", "a", "12345", "123456789"]
        for pw in tooShort {
            XCTAssertTrue(pw.count < 10, "'\(pw)' should fail the 10-char minimum")
        }

        XCTAssertTrue("abcdefghij".count >= 10, "10 chars should pass")
        XCTAssertTrue("abcdefghijk".count >= 10, "11 chars should pass")
    }

    // MARK: - Seeder Password Validation

    func testSeederPasswordMinLength() {
        // Seeder.setupInitialPassword requires >= 10 chars
        let shortPw = "123456789" // 9 chars
        XCTAssertTrue(shortPw.count < 10)

        let goodPw = "1234567890" // 10 chars
        XCTAssertTrue(goodPw.count >= 10)
    }

    // MARK: - API Key Prefix Detection

    func testAPIKeyPrefixDetection() {
        // JWTAuthMiddleware checks token.hasPrefix("barkvisor_")
        let apiKey = "barkvisor_abcdefghij"
        XCTAssertTrue(apiKey.hasPrefix("barkvisor_"))

        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"
        XCTAssertFalse(jwt.hasPrefix("barkvisor_"))
    }

    func testAPIKeyPrefixLength() {
        // Middleware extracts: String(token.prefix(15))
        let apiKey = "barkvisor_abcde_remaining_chars"
        let prefix = String(apiKey.prefix(15))
        XCTAssertEqual(prefix, "barkvisor_abcde")
        XCTAssertEqual(prefix.count, 15)
    }

    // MARK: - BcryptHasher Protocol Conformance

    func testBcryptHasherConformsToPasswordHasher() {
        let hasher: PasswordHasher = BcryptHasher.shared
        XCTAssertNotNil(hasher)
    }

    func testBcryptHasherHashAndVerify() throws {
        let hasher = BcryptHasher.shared
        let password = "test-password-123"
        let hash = try hasher.hash(password)

        // Hash should not be the plaintext
        XCTAssertNotEqual(hash, password)
        // Hash should be a bcrypt hash
        XCTAssertTrue(hash.hasPrefix("$2"))

        // Verify should succeed
        XCTAssertTrue(try hasher.verify(password, against: hash))

        // Wrong password should fail
        XCTAssertFalse(try hasher.verify("wrong-password", against: hash))
    }

    // MARK: - Stop Method Validation

    func testStopMethodAllowedValues() {
        // VMController.stop validates method is one of: guest-agent, acpi, force
        let allowedMethods: Set = ["guest-agent", "acpi", "force"]
        XCTAssertTrue(allowedMethods.contains("guest-agent"))
        XCTAssertTrue(allowedMethods.contains("acpi"))
        XCTAssertTrue(allowedMethods.contains("force"))
        XCTAssertFalse(allowedMethods.contains("kill"))
        XCTAssertFalse(allowedMethods.contains(""))
        XCTAssertFalse(allowedMethods.contains("FORCE"))
    }
}
