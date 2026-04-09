import Foundation
import GRDB
import JWTKit

public enum AuthService {
    /// Authenticate a user with username/password. Returns a signed JWT token.
    public static func login(
        username: String,
        password: String,
        hasher: PasswordHasher,
        keys: JWTKeyCollection,
        db: DatabasePool,
    ) async throws -> (token: String, user: User) {
        let user = try await db.read { db in
            try User.filter(User.Columns.username == username).fetchOne(db)
        }

        // Always perform a bcrypt verify to prevent user-enumeration via timing.
        let dummyHash = "$2b$12$000000000000000000000uKsfROku1VKyeVROaku1VKyeVROaku1a"
        let hashToVerify: String =
            if let userPassword = user?.password, !userPassword.isEmpty {
                userPassword
            } else {
                dummyHash
            }
        let passwordMatch = try hasher.verify(password, against: hashToVerify)

        guard let user else {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }

        guard !user.password.isEmpty else {
            throw BarkVisorError.forbidden(
                "Password not yet configured. Complete onboarding setup first.",
            )
        }

        guard passwordMatch else {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }

        let payload = UserPayload(
            sub: .init(value: user.id),
            username: user.username,
            exp: .init(value: Date().addingTimeInterval(2 * 60 * 60)),
        )

        let token = try await keys.sign(payload)
        return (token, user)
    }
}
