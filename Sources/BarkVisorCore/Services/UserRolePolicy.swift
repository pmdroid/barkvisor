import Foundation

/// Two Home roles (PAS-286). Not a full IAM product.
public enum UserRole: String, Codable, Sendable, CaseIterable {
    case admin
    case inference
}

/// First user on a Home is admin. Unknown stored roles fail closed as inference.
public enum UserRolePolicy {
    /// DB / API-key owner. Missing or unknown → inference.
    public static func parseStored(_ raw: String?) -> UserRole {
        guard let raw, let role = UserRole(rawValue: raw) else { return .inference }
        return role
    }

    /// Pre-RBAC console JWTs have no `role` claim; those sessions were admin.
    /// Unknown values still fail closed.
    public static func parseSession(_ raw: String?) -> UserRole {
        guard let raw, !raw.isEmpty else { return .admin }
        return UserRole(rawValue: raw) ?? .inference
    }

    public static func roleForNewUser(existingUserCount: Int) -> UserRole {
        existingUserCount == 0 ? .admin : .inference
    }

    public static func inheritKeyKind(userRole: UserRole, requested: APIKeyKind) -> APIKeyKind {
        userRole == .inference ? .inference : requested
    }

    /// Inference is narrower than admin. A signed hop claim of inference must
    /// not become admin because the member Device only has the paired admin row.
    public static func moreRestrictive(_ lhs: UserRole, _ rhs: UserRole) -> UserRole {
        lhs == .admin && rhs == .admin ? .admin : .inference
    }
}
