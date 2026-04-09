import Foundation

public struct CloudInitConfig: Codable, Sendable {
    public let sshAuthorizedKeys: [String]?
    public let userData: String?

    public init(sshAuthorizedKeys: [String]?, userData: String?) {
        self.sshAuthorizedKeys = sshAuthorizedKeys
        self.userData = userData
    }
}
