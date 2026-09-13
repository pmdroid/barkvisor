import Foundation
import GRDB

/// Moves legacy built-in Big Bear apps rows onto the membership-independent
/// `barkvisor://builtin/bigbear` identity. Only untouched GitHub-URL built-in
/// rows are rewritten: rows already flipped to the member Home origin keep
/// their URL (Home continues to fan the catalog out to them), and user-added
/// rows are never touched.
public struct M021_BuiltinAppsOrigin: DatabaseMigration {
    public static let identifier = "M021_BuiltinAppsOrigin"

    public static func migrate(_ db: GRDB.Database) throws {
        let now = iso8601.string(from: Date())
        try db.execute(
            sql: """
            UPDATE image_repositories SET url = ?, updatedAt = ?
            WHERE isBuiltIn = 1 AND repoType = 'apps' AND url = ?
            """,
            arguments: [BigBearAppCatalog.originURL, now, HomeCatalogOrigin.githubAppsURL],
        )
    }
}
