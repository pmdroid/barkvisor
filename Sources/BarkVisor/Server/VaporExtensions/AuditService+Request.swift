import BarkVisorCore
import Vapor

extension AuditService {
    /// Convenience wrapper that extracts user context from a Vapor Request.
    static func log(
        action: String,
        resourceType: String? = nil,
        resourceId: String? = nil,
        resourceName: String? = nil,
        detail: String? = nil,
        req: Vapor.Request,
    ) {
        let user = req.authenticatedUser
        log(
            action: action,
            resourceType: resourceType,
            resourceId: resourceId,
            resourceName: resourceName,
            detail: detail,
            userId: user?.userId,
            username: user?.username,
            authMethod: user?.authMethod,
            apiKeyId: user?.apiKeyId,
            db: req.db,
        )
    }
}
