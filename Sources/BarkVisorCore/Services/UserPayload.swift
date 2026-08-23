import Foundation
import JWTKit

public struct UserPayload: JWTPayload {
    public var sub: SubjectClaim
    public var username: String
    public var exp: ExpirationClaim
    /// Absent on JWTs minted before PAS-286.
    public var role: String?

    public func verify(using algorithm: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }

    public init(
        sub: SubjectClaim,
        username: String,
        exp: ExpirationClaim,
        role: String? = nil,
    ) {
        self.sub = sub
        self.username = username
        self.exp = exp
        self.role = role
    }
}
