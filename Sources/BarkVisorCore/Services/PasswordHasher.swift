import Foundation

/// Protocol for bcrypt-style password hashing, allowing services to hash and verify
/// passwords without depending on Vapor. The main app injects a Vapor Bcrypt implementation.
public protocol PasswordHasher: Sendable {
    func hash(_ password: String) throws -> String
    func verify(_ password: String, against hash: String) throws -> Bool
}
