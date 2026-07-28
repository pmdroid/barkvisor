import Foundation
import Testing

/// Ensures privileged XPC access stays behind `PrivilegeService`.
/// Controllers and other production code must not reference `HelperXPCClient` directly.
struct PrivilegeBoundaryTests {
    private static let allowedRelativePaths: Set<String> = [
        "BarkVisorCore/Services/PrivilegeService.swift",
        "BarkVisorCore/Services/HelperXPCClient.swift",
    ]

    @Test func `HelperXPCClient is only used from PrivilegeService and its own file`() throws {
        let sourcesRoot = try Self.packageSourcesRoot()
        let violations = try Self.scanForHelperXPCClient(in: sourcesRoot)

        #expect(
            violations.isEmpty,
            """
            HelperXPCClient must only appear in PrivilegeService.swift and HelperXPCClient.swift. \
            Controllers and other modules must go through PrivilegeService.shared.
            Violations:
            \(violations.joined(separator: "\n"))
            """,
        )
    }

    // MARK: - Filesystem scan

    private static func packageSourcesRoot() throws -> URL {
        // Tests/BarkVisorTests/PrivilegeBoundaryTests.swift → package root → Sources/
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent() // BarkVisorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let sources = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let isDirectory = (try? sources.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory else {
            Issue.record("Sources directory not found at \(sources.path)")
            throw ScanError.sourcesNotFound(sources.path)
        }
        return sources
    }

    private static func scanForHelperXPCClient(in sourcesRoot: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        ) else {
            throw ScanError.enumeratorFailed(sourcesRoot.path)
        }

        var violations: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }

            let relative = relativePath(of: fileURL, under: sourcesRoot)
            if allowedRelativePaths.contains(relative) { continue }

            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            if contents.contains("HelperXPCClient") {
                violations.append(relative)
            }
        }
        return violations.sorted()
    }

    private static func relativePath(of fileURL: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private enum ScanError: Error {
        case sourcesNotFound(String)
        case enumeratorFailed(String)
    }
}
