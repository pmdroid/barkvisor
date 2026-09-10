import Foundation
import GRDB

public enum HomeCatalogOrigin {
    public static let githubImagesURL =
        "https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/images.json"
    public static let githubTemplatesURL =
        "https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/templates.json"
    public static let githubAppsURL = BigBearAppCatalog.githubRepoURL
    public static let memberImagesURL = "barkvisor://home/catalog/images"
    public static let memberTemplatesURL = "barkvisor://home/catalog/templates"
    public static let memberAppsURL = "barkvisor://home/catalog/apps"
    public static let repoTypes = ["images", "templates", "apps"]

    public static func seedURL(repoType: String, isMember: Bool) -> String {
        switch repoType {
        case "images":
            isMember ? memberImagesURL : githubImagesURL
        case "templates":
            isMember ? memberTemplatesURL : githubTemplatesURL
        case "apps":
            isMember ? memberAppsURL : githubAppsURL
        default:
            isMember ? memberImagesURL : githubImagesURL
        }
    }

    public static func isGitHubBuiltIn(_ url: String) -> Bool {
        url == githubImagesURL || url == githubTemplatesURL || url == githubAppsURL
    }

    public static func isMemberOrigin(_ url: String) -> Bool {
        url == memberImagesURL || url == memberTemplatesURL || url == memberAppsURL
    }

    public static func shouldFetchRemote(url: String, memberCatalogFetchDisabled: Bool) -> Bool {
        if memberCatalogFetchDisabled, isGitHubBuiltIn(url) {
            return false
        }
        if isMemberOrigin(url) {
            return false
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    public static func flipGitHubBuiltIns(_ db: Database) throws {
        let now = iso8601.string(from: Date())
        try db.execute(
            sql: """
            UPDATE image_repositories SET url = ?, updatedAt = ?
            WHERE isBuiltIn = 1 AND repoType = 'images' AND url = ?
            """,
            arguments: [memberImagesURL, now, githubImagesURL],
        )
        try db.execute(
            sql: """
            UPDATE image_repositories SET url = ?, updatedAt = ?
            WHERE isBuiltIn = 1 AND repoType = 'templates' AND url = ?
            """,
            arguments: [memberTemplatesURL, now, githubTemplatesURL],
        )
        try db.execute(
            sql: """
            UPDATE image_repositories SET url = ?, updatedAt = ?
            WHERE isBuiltIn = 1 AND repoType = 'apps' AND url = ?
            """,
            arguments: [memberAppsURL, now, githubAppsURL],
        )
    }
}
