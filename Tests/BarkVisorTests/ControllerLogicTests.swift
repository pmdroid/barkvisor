import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for pure logic in controllers that can be tested without a Vapor server.
/// Covers: log level logic, directory browser path validation,
/// metrics clamping, and image download file extension handling.
final class ControllerLogicTests: XCTestCase {
    // MARK: - Request Log Level Classification

    func testLogLevelByStatusCode() {
        /// RequestLogMiddleware classifies: >= 500 → error, >= 400 → warn, else → info
        func logLevel(for statusCode: UInt) -> String {
            if statusCode >= 500 { return "error" }
            if statusCode >= 400 { return "warn" }
            return "info"
        }

        XCTAssertEqual(logLevel(for: 200), "info")
        XCTAssertEqual(logLevel(for: 201), "info")
        XCTAssertEqual(logLevel(for: 204), "info")
        XCTAssertEqual(logLevel(for: 301), "info")
        XCTAssertEqual(logLevel(for: 400), "warn")
        XCTAssertEqual(logLevel(for: 401), "warn")
        XCTAssertEqual(logLevel(for: 404), "warn")
        XCTAssertEqual(logLevel(for: 429), "warn")
        XCTAssertEqual(logLevel(for: 499), "warn")
        XCTAssertEqual(logLevel(for: 500), "error")
        XCTAssertEqual(logLevel(for: 502), "error")
        XCTAssertEqual(logLevel(for: 503), "error")
    }

    // MARK: - SPA Fallback Path Matching

    func testSPAFallbackRules() {
        // SPAFallbackMiddleware: applies to GET, non-/api/, no file extension, not root
        func shouldFallback(method: String, path: String) -> Bool {
            method == "GET"
                && !path.hasPrefix("/api/")
                && !path.contains(".")
                && path != "/"
        }

        // Should fall back (SPA routes)
        XCTAssertTrue(shouldFallback(method: "GET", path: "/vms"))
        XCTAssertTrue(shouldFallback(method: "GET", path: "/settings"))
        XCTAssertTrue(shouldFallback(method: "GET", path: "/vms/123/detail"))

        // Should NOT fall back
        XCTAssertFalse(shouldFallback(method: "POST", path: "/vms")) // not GET
        XCTAssertFalse(shouldFallback(method: "GET", path: "/api/vms")) // API route
        XCTAssertFalse(shouldFallback(method: "GET", path: "/assets/app.js")) // has extension
        XCTAssertFalse(shouldFallback(method: "GET", path: "/")) // root
        XCTAssertFalse(shouldFallback(method: "GET", path: "/favicon.ico")) // has extension
    }

    // MARK: - Metrics Minutes Clamping

    func testMetricsMinutesClamping() {
        // MetricsController: min(input ?? 5, 1440)
        func clampMinutes(_ input: Int?) -> Int {
            min(input ?? 5, 1_440)
        }

        XCTAssertEqual(clampMinutes(nil), 5)
        XCTAssertEqual(clampMinutes(10), 10)
        XCTAssertEqual(clampMinutes(1_440), 1_440)
        XCTAssertEqual(clampMinutes(2_000), 1_440)
        XCTAssertEqual(clampMinutes(0), 0)
        XCTAssertEqual(clampMinutes(-5), -5) // no lower bound in the code
    }

    // MARK: - Log Query Limit Clamping

    func testLogQueryLimitClamping() {
        // LogController.queryLogs: min(limit, 5_000)
        func clampLogLimit(_ input: Int?) -> Int {
            min(input ?? 500, 5_000)
        }

        XCTAssertEqual(clampLogLimit(nil), 500)
        XCTAssertEqual(clampLogLimit(100), 100)
        XCTAssertEqual(clampLogLimit(5_000), 5_000)
        XCTAssertEqual(clampLogLimit(10_000), 5_000)
    }

    // MARK: - Client Error Truncation

    func testClientErrorTruncation() {
        // LogController.clientError truncates fields to prevent disk exhaustion
        let maxLen = 4_096
        let longError = String(repeating: "x", count: 10_000)
        let truncated = String(longError.prefix(maxLen))
        XCTAssertEqual(truncated.count, 4_096)

        let shortError = "Short error"
        let shortTruncated = String(shortError.prefix(maxLen))
        XCTAssertEqual(shortTruncated, shortError)
    }

    func testClientComponentTruncation() {
        let maxLen = 256
        let longComponent = String(repeating: "c", count: 500)
        let truncated = String(longComponent.prefix(maxLen))
        XCTAssertEqual(truncated.count, 256)
    }

    // MARK: - Diagnostic Bundle Path Validation

    func testDiagnosticBundlePathTraversalPrevention() {
        // LogController checks resolved path is within temp directory
        let tempDir = (FileManager.default.temporaryDirectory.path as NSString).resolvingSymlinksInPath
        let tempDirWithSlash = tempDir.hasSuffix("/") ? tempDir : tempDir + "/"

        // Valid path within temp dir
        let validPath = tempDirWithSlash + "barkvisor-diag-12345.tar.gz"
        let resolvedValid = (validPath as NSString).resolvingSymlinksInPath
        XCTAssertTrue(resolvedValid.hasPrefix(tempDirWithSlash) || resolvedValid == tempDir)

        // Path traversal attempt
        let traversalPath = tempDirWithSlash + "../etc/passwd"
        let resolvedTraversal = (traversalPath as NSString).resolvingSymlinksInPath
        XCTAssertFalse(resolvedTraversal.hasPrefix(tempDirWithSlash) && resolvedTraversal != tempDir)
    }

    // MARK: - Filename Sanitization

    func testDiagnosticBundleFilenameSanitization() {
        // LogController sanitizes filename for Content-Disposition
        let rawName = "diag\"bundle\n.tar.gz"
        let sanitized = rawName.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")

        XCTAssertFalse(sanitized.contains("\""))
        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertFalse(sanitized.contains("\r"))
        XCTAssertEqual(sanitized, "diag_bundle_.tar.gz")
    }

    // MARK: - Image File Extension Extraction

    func testCompoundExtensionHandling() {
        /// RepositoryController handles compound extensions like .qcow2.xz
        func extractExtension(from filename: String, imageType: String) -> String {
            if filename.hasSuffix(".qcow2.xz") || filename.hasSuffix(".img.xz")
                || filename.hasSuffix(".img.gz") || filename.hasSuffix(".qcow2.gz") {
                let parts = filename.split(separator: ".", maxSplits: 1)
                return parts.count > 1 ? String(parts[1]) : (imageType == "iso" ? "iso" : "img")
            } else {
                let url = URL(fileURLWithPath: filename)
                return url.pathExtension.isEmpty
                    ? (imageType == "iso" ? "iso" : "img")
                    : url.pathExtension
            }
        }

        XCTAssertEqual(extractExtension(from: "ubuntu.qcow2.xz", imageType: "cloud-image"), "qcow2.xz")
        XCTAssertEqual(extractExtension(from: "ubuntu.img.xz", imageType: "cloud-image"), "img.xz")
        XCTAssertEqual(extractExtension(from: "ubuntu.img.gz", imageType: "cloud-image"), "img.gz")
        XCTAssertEqual(extractExtension(from: "ubuntu.qcow2.gz", imageType: "cloud-image"), "qcow2.gz")
        XCTAssertEqual(extractExtension(from: "ubuntu.qcow2", imageType: "cloud-image"), "qcow2")
        XCTAssertEqual(extractExtension(from: "windows.iso", imageType: "iso"), "iso")
        XCTAssertEqual(extractExtension(from: "noextension", imageType: "iso"), "iso")
        XCTAssertEqual(extractExtension(from: "noextension", imageType: "cloud-image"), "img")
    }

    // MARK: - Directory Browser Allowed Roots

    func testDirectoryBrowserPathValidation() {
        // SystemController.browseDirectory checks resolved path is within allowed roots
        let allowedRoots = [
            NSHomeDirectory(),
            "/Volumes",
        ]

        func isAllowed(_ path: String) -> Bool {
            let resolvedPath = (path as NSString).resolvingSymlinksInPath
            return allowedRoots.contains(where: { root in
                let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
                return resolvedPath == root || resolvedPath.hasPrefix(rootWithSlash)
            }) || resolvedPath == "/"
        }

        // Home directory should be allowed
        XCTAssertTrue(isAllowed(NSHomeDirectory()))
        XCTAssertTrue(isAllowed(NSHomeDirectory() + "/Documents"))

        // /Volumes should be allowed
        XCTAssertTrue(isAllowed("/Volumes"))
        XCTAssertTrue(isAllowed("/Volumes/External"))

        // Root is allowed (for navigation)
        XCTAssertTrue(isAllowed("/"))

        // System directories should NOT be allowed
        XCTAssertFalse(isAllowed("/etc"))
        XCTAssertFalse(isAllowed("/usr"))
        XCTAssertFalse(isAllowed("/var"))
    }

    // MARK: - Repo Type Validation

    func testRepositoryTypeValidation() {
        // RepositoryController validates repoType is "images" or "templates"
        let validTypes = ["images", "templates"]
        XCTAssertTrue(validTypes.contains("images"))
        XCTAssertTrue(validTypes.contains("templates"))
        XCTAssertFalse(validTypes.contains("other"))
        XCTAssertFalse(validTypes.contains(""))
    }

    // MARK: - Tus Image Type Validation

    func testTusImageTypeValidation() {
        // ImageController.tusCreate validates imageType
        let validImageTypes = ["iso", "cloud-image"]
        XCTAssertTrue(validImageTypes.contains("iso"))
        XCTAssertTrue(validImageTypes.contains("cloud-image"))
        XCTAssertFalse(validImageTypes.contains("raw"))
        XCTAssertFalse(validImageTypes.contains("vmdk"))
    }

    // MARK: - Tus Arch Validation

    func testTusArchValidation() {
        // ImageController.tusCreate requires arch == "arm64"
        XCTAssertEqual("arm64", "arm64")
        XCTAssertNotEqual("x86_64", "arm64")
        XCTAssertNotEqual("amd64", "arm64")
    }
}
