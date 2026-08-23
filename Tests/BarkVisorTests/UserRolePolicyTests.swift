import Testing
@testable import BarkVisorCore

@Suite("Home RBAC roles (PAS-286)")
struct UserRolePolicyTests {
    @Test func `first user on a Home is admin`() {
        #expect(UserRolePolicy.roleForNewUser(existingUserCount: 0) == .admin)
        #expect(UserRolePolicy.roleForNewUser(existingUserCount: 1) == .inference)
        #expect(UserRolePolicy.roleForNewUser(existingUserCount: 2) == .inference)
    }

    @Test func `stored unknown role fails closed as inference`() {
        #expect(UserRolePolicy.parseStored(nil) == .inference)
        #expect(UserRolePolicy.parseStored("") == .inference)
        #expect(UserRolePolicy.parseStored("owner") == .inference)
        #expect(UserRolePolicy.parseStored("admin") == .admin)
        #expect(UserRolePolicy.parseStored("inference") == .inference)
    }

    @Test func `pre-RBAC session JWT without role stays admin`() {
        #expect(UserRolePolicy.parseSession(nil) == .admin)
        #expect(UserRolePolicy.parseSession("") == .admin)
        #expect(UserRolePolicy.parseSession("inference") == .inference)
        #expect(UserRolePolicy.parseSession("nope") == .inference)
    }

    @Test func `inference user cannot mint a full key`() {
        #expect(
            UserRolePolicy.inheritKeyKind(userRole: .inference, requested: .full) == .inference,
        )
        #expect(
            UserRolePolicy.inheritKeyKind(userRole: .admin, requested: .inference) == .inference,
        )
        #expect(UserRolePolicy.inheritKeyKind(userRole: .admin, requested: .full) == .full)
    }

    @Test func `moreRestrictive never elevates inference to admin`() {
        #expect(UserRolePolicy.moreRestrictive(.admin, .admin) == .admin)
        #expect(UserRolePolicy.moreRestrictive(.admin, .inference) == .inference)
        #expect(UserRolePolicy.moreRestrictive(.inference, .admin) == .inference)
        #expect(UserRolePolicy.moreRestrictive(.inference, .inference) == .inference)
    }
}
