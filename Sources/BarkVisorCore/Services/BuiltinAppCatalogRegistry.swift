import Foundation

/// Registry of `barkvisor://builtin/<name>` app catalogs.
///
/// The URL is a membership-independent identity for a shipped catalog: it is
/// stable across home and member Devices and never handed out to users. The
/// registry decides how each built-in is materialised — either from manifests
/// bundled in the binary (`.bundled`) or by fetching a public zipball over
/// https (`.fetch`). Unknown or malformed `barkvisor://` URLs resolve to `nil`
/// and must be rejected, never fetched.
public enum BuiltinAppCatalogRegistry {
    public static let scheme = "barkvisor"
    public static let host = "builtin"
    private static let originPrefix = "barkvisor://builtin/"

    public enum Backing: Sendable {
        /// Catalog ships inside the binary; load bytes without any network access.
        case bundled(@Sendable () throws -> Data)
        /// Catalog is materialised from a public zipball URL fetched over https.
        case fetch(zipballURL: String)
    }

    public struct Entry: Sendable {
        public let name: String
        public let displayName: String
        public let originURL: String
        public let backing: Backing

        public init(
            name: String,
            displayName: String,
            originURL: String,
            backing: Backing,
        ) {
            self.name = name
            self.displayName = displayName
            self.originURL = originURL
            self.backing = backing
        }
    }

    public static let linuxServer = Entry(
        name: "linuxserver",
        displayName: LinuxServerAppCatalog.catalogName,
        originURL: LinuxServerAppCatalog.originURL,
        backing: .bundled { try LinuxServerAppCatalog.encodedDocument() },
    )

    public static let bigBear = Entry(
        name: "bigbear",
        displayName: BigBearAppCatalog.catalogName,
        originURL: BigBearAppCatalog.originURL,
        backing: .fetch(zipballURL: BigBearAppCatalog.zipballURL),
    )

    public static let all: [Entry] = [linuxServer, bigBear]

    /// Strict parse of the `<name>` segment of `barkvisor://builtin/<name>`.
    ///
    /// Requires the exact lowercase scheme `barkvisor`, lowercase host
    /// `builtin`, and exactly one lowercase slug segment (letters, digits,
    /// hyphens; no leading/trailing hyphen). Anything else — uppercase, extra
    /// path segments, ports, queries, fragments, empty names — returns `nil`.
    public static func parseName(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(originPrefix) else { return nil }
        let segment = String(trimmed.dropFirst(originPrefix.count))
        guard !segment.isEmpty, segment.count <= 64 else { return nil }
        // Lowercase ASCII slug: a-z, 0-9, hyphens only. Rejects uppercase,
        // underscores, slashes, dots, ports, queries, and fragments.
        let isSlug = segment.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar.value == 0x2D
        }
        guard isSlug, !segment.hasPrefix("-"), !segment.hasSuffix("-") else { return nil }
        return segment
    }

    /// Registry entry for a canonical built-in origin URL, `nil` otherwise.
    public static func resolve(_ url: String) -> Entry? {
        guard let name = parseName(url) else { return nil }
        return all.first { $0.name == name }
    }

    /// True for any well-formed `barkvisor://builtin/<name>` URL, whether or
    /// not the name is a registered catalog.
    public static func isBuiltinOrigin(_ url: String) -> Bool {
        parseName(url) != nil
    }
}
