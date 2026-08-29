import Foundation
import Testing
@testable import BarkVisorCore

/// PAS-294: privileged XPC helper is gone. Fail if it is reintroduced.
struct PrivilegeBoundaryTests {
    @Test func `helper XPC types are not referenced in Sources`() throws {
        let sourcesRoot = try Self.packageSourcesRoot()
        let violations = try Self.scan(
            in: sourcesRoot,
            needles: ["HelperXPCClient", "BarkVisorHelper", "SMJobBless", "XPC connection invalidated"],
        )

        #expect(
            violations.isEmpty,
            """
            Privileged helper / XPC client must stay removed (PAS-294). \
            Attach to Homebrew socket_vmnet from the root Device daemon. No SMJobBless.
            Violations:
            \(violations.joined(separator: "\n"))
            """,
        )
    }

    @Test func `leftover helper inventory lists launchd and libexec without reconnect`() {
        let paths = LeftoverHelperInventory.candidatePaths
        #expect(paths.contains("/Library/LaunchDaemons/dev.barkvisor.helper.plist"))
        #expect(paths.contains("/Library/PrivilegedHelperTools/dev.barkvisor.helper"))
        #expect(paths.contains("/usr/local/libexec/dev.barkvisor.helper"))
        let present = LeftoverHelperInventory.leftoverPaths(fileExists: { $0.hasSuffix(".plist") })
        #expect(present == ["/Library/LaunchDaemons/dev.barkvisor.helper.plist"])
        let warning = LeftoverHelperInventory.warningMessage(paths: present)
        #expect(warning.contains("launchctl bootout"))
        #expect(!warning.contains("HelperXPCClient"))
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

    private static func scan(in sourcesRoot: URL, needles: [String]) throws -> [String] {
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
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            for needle in needles where contents.contains(needle) {
                violations.append("\(relative): \(needle)")
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
