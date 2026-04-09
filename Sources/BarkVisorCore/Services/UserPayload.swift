import Foundation
import JWTKit

public struct UserPayload: JWTPayload {
    public var sub: SubjectClaim
    public var username: String
    public var exp: ExpirationClaim

    public func verify(using algorithm: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }

    public init(
        sub: SubjectClaim,
        username: String,
        exp: ExpirationClaim,
    ) {
        self.sub = sub
        self.username = username
        self.exp = exp
    }
}
