import BarkVisorCore
import Vapor

/// Vapor Bcrypt adapter for the PasswordHasher protocol.
struct BcryptHasher: BarkVisorCore.PasswordHasher {
    static let shared = BcryptHasher()

    func hash(_ password: String) throws -> String {
        try Bcrypt.hash(password)
    }

    func verify(_ password: String, against hash: String) throws -> Bool {
        try Bcrypt.verify(password, created: hash)
    }
}
