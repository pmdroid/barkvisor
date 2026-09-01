import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for pure logic in controllers that can be tested without a Vapor server.
struct ControllerLogicTests {
    // MARK: - Request Log Level Classification

    @Test func `log level by status code`() {
        func logLevel(for statusCode: UInt) -> String {
            if statusCode >= 500 { return "error" }
            if statusCode >= 400 { return "warn" }
            return "info"
        }

        #expect(logLevel(for: 200) == "info")
        #expect(logLevel(for: 201) == "info")
        #expect(logLevel(for: 204) == "info")
        #expect(logLevel(for: 301) == "info")
        #expect(logLevel(for: 400) == "warn")
        #expect(logLevel(for: 401) == "warn")
        #expect(logLevel(for: 404) == "warn")
        #expect(logLevel(for: 429) == "warn")
        #expect(logLevel(for: 499) == "warn")
        #expect(logLevel(for: 500) == "error")
        #expect(logLevel(for: 502) == "error")
        #expect(logLevel(for: 503) == "error")
    }

    // MARK: - SPA Fallback Path Matching

    @Test func `spa fallback rules`() {
        func shouldFallback(method: String, path: String) -> Bool {
            method == "GET" && !path.hasPrefix("/api/") && !path.contains(".") && path != "/"
        }

        #expect(shouldFallback(method: "GET", path: "/vms"))
        #expect(shouldFallback(method: "GET", path: "/settings"))
        #expect(shouldFallback(method: "GET", path: "/vms/123/detail"))

        #expect(!shouldFallback(method: "POST", path: "/vms"))
        #expect(!shouldFallback(method: "GET", path: "/api/vms"))
        #expect(!shouldFallback(method: "GET", path: "/assets/app.js"))
        #expect(!shouldFallback(method: "GET", path: "/"))
        #expect(!shouldFallback(method: "GET", path: "/favicon.ico"))
    }

    // MARK: - Metrics Minutes Clamping

    @Test func `metrics minutes clamping`() {
        func clampMinutes(_ input: Int?) -> Int {
            min(input ?? 5, 1_440)
        }

        #expect(clampMinutes(nil) == 5)
        #expect(clampMinutes(10) == 10)
        #expect(clampMinutes(1_440) == 1_440)
        #expect(clampMinutes(2_000) == 1_440)
        #expect(clampMinutes(0) == 0)
        #expect(clampMinutes(-5) == -5)
    }

    @Test func `system stats history minutes clamp to ring retention`() {
        let requested = 1_440
        let minutes = MetricsCollector.clampSystemStatsMinutes(requested)
        #expect(minutes == MetricsCollector.systemStatsRetentionMinutes)
        #expect(minutes < 1_440)
    }

    // MARK: - Log Query Limit Clamping

    @Test func `log query limit clamping`() {
        func clampLogLimit(_ input: Int?) -> Int {
            min(input ?? 500, 5_000)
        }

        #expect(clampLogLimit(nil) == 500)
        #expect(clampLogLimit(100) == 100)
        #expect(clampLogLimit(5_000) == 5_000)
        #expect(clampLogLimit(10_000) == 5_000)
    }

    // MARK: - Client Error Truncation

    @Test func `client error truncation`() {
        let maxLen = 4_096
        let longError = String(repeating: "x", count: 10_000)
        let truncated = String(longError.prefix(maxLen))
        #expect(truncated.count == 4_096)

        let shortError = "Short error"
        let shortTruncated = String(shortError.prefix(maxLen))
        #expect(shortTruncated == shortError)
    }

    @Test func `client component truncation`() {
        let maxLen = 256
        let longComponent = String(repeating: "c", count: 500)
        let truncated = String(longComponent.prefix(maxLen))
        #expect(truncated.count == 256)
    }

    // MARK: - Diagnostic Bundle Path Validation

    @Test func `diagnostic bundle path traversal prevention`() {
        let tempDir = (FileManager.default.temporaryDirectory.path as NSString).resolvingSymlinksInPath
        let tempDirWithSlash = tempDir.hasSuffix("/") ? tempDir : tempDir + "/"

        let validPath = tempDirWithSlash + "barkvisor-diag-12345.tar.gz"
        let resolvedValid = (validPath as NSString).resolvingSymlinksInPath
        #expect(resolvedValid.hasPrefix(tempDirWithSlash) || resolvedValid == tempDir)

        let traversalPath = tempDirWithSlash + "../etc/passwd"
        let resolvedTraversal = (traversalPath as NSString).resolvingSymlinksInPath
        #expect(!(resolvedTraversal.hasPrefix(tempDirWithSlash) && resolvedTraversal != tempDir))
    }

    // MARK: - Filename Sanitization

    @Test func `diagnostic bundle filename sanitization`() {
        let rawName = "diag\"bundle\n.tar.gz"
        let sanitized = rawName.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")

        #expect(!sanitized.contains("\""))
        #expect(!sanitized.contains("\n"))
        #expect(!sanitized.contains("\r"))
        #expect(sanitized == "diag_bundle_.tar.gz")
    }

    // MARK: - Image File Extension Extraction

    @Test func `compound extension handling`() {
        func extractExtension(from filename: String, imageType: String) -> String {
            if filename.hasSuffix(".qcow2.xz") || filename.hasSuffix(".img.xz")
                || filename.hasSuffix(".img.gz") || filename.hasSuffix(".qcow2.gz") {
                let parts = filename.split(separator: ".", maxSplits: 1)
                return parts.count > 1 ? String(parts[1]) : (imageType == "iso" ? "iso" : "img")
            } else {
                let url = URL(fileURLWithPath: filename)
                return url.pathExtension.isEmpty ? (imageType == "iso" ? "iso" : "img") : url.pathExtension
            }
        }

        #expect(extractExtension(from: "ubuntu.qcow2.xz", imageType: "cloud-image") == "qcow2.xz")
        #expect(extractExtension(from: "ubuntu.img.xz", imageType: "cloud-image") == "img.xz")
        #expect(extractExtension(from: "ubuntu.img.gz", imageType: "cloud-image") == "img.gz")
        #expect(extractExtension(from: "ubuntu.qcow2.gz", imageType: "cloud-image") == "qcow2.gz")
        #expect(extractExtension(from: "ubuntu.qcow2", imageType: "cloud-image") == "qcow2")
        #expect(extractExtension(from: "windows.iso", imageType: "iso") == "iso")
        #expect(extractExtension(from: "noextension", imageType: "iso") == "iso")
        #expect(extractExtension(from: "noextension", imageType: "cloud-image") == "img")
    }

    // MARK: - Directory Browser Allowed Roots

    @Test func `directory browser path validation`() {
        #expect(DirectoryBrowser.isAllowed(NSHomeDirectory()))
        #expect(DirectoryBrowser.isAllowed(NSHomeDirectory() + "/Documents"))
        #if os(macOS)
            #expect(DirectoryBrowser.isAllowed("/Users", home: "/var/root"))
            #expect(DirectoryBrowser.isAllowed("/Users/pascal/External", home: "/var/root"))
        #else
            #expect(!DirectoryBrowser.isAllowed("/Users", home: "/var/root"))
            #expect(!DirectoryBrowser.isAllowed("/Users/pascal/External", home: "/var/root"))
        #endif
        #expect(DirectoryBrowser.isAllowed("/Volumes"))
        #expect(DirectoryBrowser.isAllowed("/Volumes/Data"))
        #expect(DirectoryBrowser.isAllowed("/Volumes/Data/workspace"))
        #expect(DirectoryBrowser.isAllowed("/Volumes/External"))
        #expect(DirectoryBrowser.parentPath(of: "/Volumes/Data") == "/Volumes")
        #expect(DirectoryBrowser.isAllowed("/mnt"))
        #expect(DirectoryBrowser.isAllowed("/mnt/data"))
        #expect(DirectoryBrowser.isAllowed("/media/usb"))
        #expect(DirectoryBrowser.isAllowed("/"))
        #expect(!DirectoryBrowser.isAllowed("/etc"))
        #expect(!DirectoryBrowser.isAllowed("/usr"))
        #expect(!DirectoryBrowser.isAllowed("/var"))
        #expect(DirectoryBrowser.isAllowed("/var/lib/barkvisor/images", extraRoots: ["/var/lib/barkvisor/images"]))
        #expect(DirectoryBrowser.isAllowed("/var/lib/barkvisor/images/ubuntu", extraRoots: ["/var/lib/barkvisor/images"]))
        #expect(!DirectoryBrowser.isAllowed("/var/lib/barkvisor", extraRoots: ["/var/lib/barkvisor/images"]))
        #expect(DirectoryBrowser.isAllowed("/var/lib/barkvisor", extraRoots: ["/var/lib/barkvisor"]))
        #expect(DirectoryBrowser.isAllowed("/var/lib/barkvisor/disks", extraRoots: ["/var/lib/barkvisor"]))
    }

    @Test func `directory browser lists roots and can leave an empty extra root`() {
        let home = "/Users/pascal"
        let dataDir = "/var/lib/barkvisor"
        let disks = "/var/lib/barkvisor/disks"
        let extra = [dataDir, disks]
        let present: Set<String> = [home, "/mnt", dataDir, disks]
        let roots = DirectoryBrowser.rootEntries(
            extraRoots: extra,
            home: home,
            exists: { present.contains($0) },
        )
        #expect(roots.map(\.path).contains(home))
        #expect(roots.map(\.path).contains("/mnt"))
        #expect(roots.map(\.path).contains(dataDir))
        #expect(roots.map(\.path).contains(disks))
        #expect(!roots.map(\.path).contains("/Volumes"))
        #expect(DirectoryBrowser.parentPath(of: disks, extraRoots: extra, home: home) == dataDir)
        #expect(DirectoryBrowser.parentPath(of: dataDir, extraRoots: extra, home: home) == "")
        #expect(DirectoryBrowser.parentPath(of: home, extraRoots: extra, home: home) == "")
        #expect(DirectoryBrowser.parentPath(of: "/", extraRoots: extra, home: home) == nil)
    }

    @Test func `directory browser list empty path returns roots`() throws {
        let entries = try DirectoryBrowser.list(path: "")
        #expect(entries.map(\.path).contains(NSHomeDirectory()))
        #expect(throws: BarkVisorError.self) {
            try DirectoryBrowser.list(path: "/etc")
        }
    }

    @Test func `directory browser maps unreadable folder to typed permission error`() throws {
        guard getuid() != 0 else { return }
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        let locked = (base as NSString).appendingPathComponent("locked")
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? FileManager.default.removeItem(atPath: base)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        do {
            _ = try DirectoryBrowser.list(path: locked, extraRoots: [base])
            Issue.record("Expected a permission error for an unreadable folder")
        } catch let error as BarkVisorError {
            #expect(error.code == "permission_denied")
            #expect(error.httpStatus == 403)
            let reason = error.sanitizedDescription
            #expect(!reason.isEmpty)
            #expect(!reason.contains(locked))
        }
    }

    @Test func `directory browser rejects symlink escape and lists Volumes Data`() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let escape = (base as NSString).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: escape, withDestinationPath: "/etc")
        #expect(!DirectoryBrowser.isAllowed(escape, extraRoots: [base]))
        #expect(throws: BarkVisorError.self) {
            try DirectoryBrowser.list(path: escape, extraRoots: [base])
        }

        #if os(macOS)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: "/Volumes/Data", isDirectory: &isDir),
               isDir.boolValue {
                do {
                    let entries = try DirectoryBrowser.list(path: "/Volumes/Data")
                    #expect(entries.contains { $0.name == ".." && $0.path == "/Volumes" })
                } catch let error as BarkVisorError {
                    #expect(error.code == "permission_denied")
                    #expect(error.httpStatus == 403)
                }
            }
        #endif
    }

    @Test func `directory browser permission error detection`() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue))
        #expect(DirectoryBrowser.isPermissionError(posix))
        let cocoa = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoPermission.rawValue,
        )
        #expect(DirectoryBrowser.isPermissionError(cocoa))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.EPERM.rawValue),
                ),
            ],
        )
        #expect(DirectoryBrowser.isPermissionError(wrapped))
        let other = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
        #expect(!DirectoryBrowser.isPermissionError(other))
    }

    @Test func `directory browser createFolder`() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let created = try DirectoryBrowser.createFolder(parentPath: base, name: "vms", extraRoots: [base])
        #expect(created.path == (base as NSString).appendingPathComponent("vms"))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(throws: BarkVisorError.self) {
            try DirectoryBrowser.createFolder(parentPath: "", name: "x")
        }
    }

    // MARK: - Repo Type Validation

    @Test func `repository type validation`() {
        let validTypes = ["images", "templates"]
        #expect(validTypes.contains("images"))
        #expect(validTypes.contains("templates"))
        #expect(!validTypes.contains("other"))
        #expect(!validTypes.contains(""))
    }

    // MARK: - Tus Image Type Validation

    @Test func `tus image type validation`() {
        let validImageTypes = ["iso", "cloud-image"]
        #expect(validImageTypes.contains("iso"))
        #expect(validImageTypes.contains("cloud-image"))
        #expect(!validImageTypes.contains("raw"))
        #expect(!validImageTypes.contains("vmdk"))
    }

    // MARK: - Tus Arch Validation

    @Test func `tus arch validation`() {
        #expect("arm64" == "arm64")
        #expect("x86_64" != "arm64")
        #expect("amd64" != "arm64")
    }

    // MARK: - System Capabilities

    @Test func `currentCapabilities returns platform and accelerator fields`() {
        let caps = SystemCapabilitiesController.currentCapabilities()
        #expect(!caps.platform.isEmpty)
        #expect(!caps.accelerator.isEmpty)
        #expect(caps.hostArch == "arm64" || caps.hostArch == "x86_64" || !caps.hostArch.isEmpty)
        #expect(caps.accelerator == PlatformCapabilities.accelerator)
        #expect(caps.hostCpuCount == PlatformHost.cpuCount)
        #expect(caps.hostCpuCount >= 1)
        #expect(
            caps.supportsBridgedNetworking
                == HostInventoryService.bridgedNetworkingSupported(
                    platformSupports: PlatformCapabilities.supportsBridgedNetworking,
                    qemuBridgeHelper: HostInventoryService.qemuBridgeHelperPresent(),
                    os: PlatformHost.platformName,
                ),
        )
        #expect(caps.supportsManagedBridgeDaemon == PlatformCapabilities.supportsManagedBridgeDaemon)
        #expect(caps.supportsHostBridgeManagement == PlatformCapabilities.supportsHostBridgeManagement)
        #expect(caps.supportsHostMutation == PlatformCapabilities.supportsHostMutation)
        #expect(caps.supportsUSBPassthrough == PlatformCapabilities.supportsUSBPassthrough)
        #expect(caps.supportsInAppUpdate == PlatformCapabilities.supportsInAppUpdate)
        let vfioFacts = VFIOProbe.live()
        #expect(
            caps.supportsVFIO
                == VFIOProbe.vfioSupported(os: PlatformHost.platformName, facts: vfioFacts),
        )
        #expect(
            caps.supportsGPUPassthrough
                == VFIOProbe.gpuPassthroughSupported(os: PlatformHost.platformName, facts: vfioFacts),
        )
        #expect(caps.details.count == CapabilityCode.allCases.count)
        #expect(caps.networkModes.map(\.mode) == ["nat", "bridged", "isolated"])
        #expect(caps.networkModes.first { $0.mode == "nat" }?.supported == true)
        #expect(caps.networkModes.first { $0.mode == "isolated" }?.supported == true)
        #expect(caps.runnableArches == [caps.hostArch])
        #expect(caps.inventorySchemaVersion == HostInventoryService.currentSchemaVersion)
        #if os(macOS)
            #expect(caps.supportsManagedBridgeDaemon)
            #expect(!caps.supportsHostBridgeManagement)
        #elseif os(Linux)
            #expect(caps.supportsBridgedNetworking == HostInventoryService.qemuBridgeHelperPresent())
            #expect(!caps.supportsManagedBridgeDaemon)
            #expect(caps.supportsHostBridgeManagement)
        #endif
    }

    @Test func `validateCPUCount rejects more vCPUs than host allows after reserve`() throws {
        let host = PlatformHost.cpuCount
        let max = VMLifecycleService.maxAssignableCPUs()
        try VMLifecycleService.validateCPUCount(1)
        try VMLifecycleService.validateCPUCount(max)
        #expect(throws: BarkVisorError.self) {
            try VMLifecycleService.validateCPUCount(max + 1)
        }
        #expect(throws: BarkVisorError.self) {
            try VMLifecycleService.validateCPUCount(host + 1)
        }
        #expect(throws: BarkVisorError.self) {
            try VMLifecycleService.validateCPUCount(0)
        }
    }

    @Test func `setup joined requires receipt and admin identity`() {
        #expect(!SetupController.shouldReportJoined(hasReceipt: false, hasAdmin: false))
        #expect(!SetupController.shouldReportJoined(hasReceipt: true, hasAdmin: false))
        #expect(!SetupController.shouldReportJoined(hasReceipt: false, hasAdmin: true))
        #expect(SetupController.shouldReportJoined(hasReceipt: true, hasAdmin: true))
    }
}
