import CryptoKit
import Foundation

// MARK: - Types

public struct UpdateInfo: Codable, Sendable {
    public let version: String
    public let pkgURL: String
    public let checksumURL: String?
    public let changelog: String
    public let publishedAt: String
    public let isPrerelease: Bool

    public init(
        version: String,
        pkgURL: String,
        checksumURL: String?,
        changelog: String,
        publishedAt: String,
        isPrerelease: Bool,
    ) {
        self.version = version
        self.pkgURL = pkgURL
        self.checksumURL = checksumURL
        self.changelog = changelog
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
    }
}

public enum UpdateChannel: String, Codable, Sendable {
    case stable
    case beta
}

// MARK: - GitHub Release API Types

private struct GitHubRelease: Decodable {
    let tagName: String
    let prerelease: Bool
    let body: String?
    let publishedAt: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case body
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - UpdateService

public actor UpdateService {
    private static let defaultReleasesURL = "https://api.github.com/repos/pmdroid/barkvisor/releases"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    public init() {}

    /// Resolves the update URL: explicit override > env var > default.
    private func resolvedURL(override: String?) -> String {
        if let override, !override.isEmpty { return override }
        return ProcessInfo.processInfo.environment["BARKVISOR_UPDATE_URL"]
            ?? Self.defaultReleasesURL
    }

    // MARK: - Check for Updates

    public func checkForUpdates(channel: UpdateChannel, urlOverride: String? = nil) async throws
        -> UpdateInfo? {
        let currentVersion = Config.version
        let url = resolvedURL(override: urlOverride)
        guard let requestURL = URL(string: url) else {
            throw BarkVisorError.updateFailed("Invalid update URL: \(url)")
        }
        var request = URLRequest(url: requestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BarkVisor/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BarkVisorError.updateFailed("GitHub API returned HTTP \(statusCode)")
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

        // Filter by channel
        let candidates: [GitHubRelease] =
            switch channel {
            case .stable:
                releases.filter { !$0.prerelease }
            case .beta:
                releases
            }

        // Find the newest release that is newer than current version
        for release in candidates {
            let version =
                release.tagName.hasPrefix("v")
                    ? String(release.tagName.dropFirst())
                    : release.tagName

            guard Self.isVersion(version, newerThan: currentVersion) else { continue }

            // Find PKG asset
            guard let pkgAsset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }) else {
                continue
            }

            // Find checksum asset (optional)
            let checksumAsset = release.assets.first(where: { $0.name.hasSuffix(".pkg.sha256") })

            return UpdateInfo(
                version: version,
                pkgURL: pkgAsset.browserDownloadURL,
                checksumURL: checksumAsset?.browserDownloadURL,
                changelog: release.body ?? "",
                publishedAt: release.publishedAt ?? "",
                isPrerelease: release.prerelease,
            )
        }

        return nil
    }

    // MARK: - Lookup Specific Release

    /// Fetches release info for a specific version from the GitHub releases API.
    /// This ensures URLs are constructed from the canonical source, not from user input.
    public func lookupRelease(version: String, channel: UpdateChannel, urlOverride: String? = nil)
        async throws -> UpdateInfo {
        let url = resolvedURL(override: urlOverride)
        guard let requestURL = URL(string: url) else {
            throw BarkVisorError.updateFailed("Invalid update URL: \(url)")
        }
        var request = URLRequest(url: requestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BarkVisor/\(Config.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BarkVisorError.updateFailed("GitHub API returned HTTP \(statusCode)")
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

        // Filter by channel
        let candidates: [GitHubRelease] =
            switch channel {
            case .stable:
                releases.filter { !$0.prerelease }
            case .beta:
                releases
            }

        // Find the release matching the requested version
        for release in candidates {
            let releaseVersion =
                release.tagName.hasPrefix("v")
                    ? String(release.tagName.dropFirst())
                    : release.tagName

            guard releaseVersion == version else { continue }

            guard let pkgAsset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }) else {
                throw BarkVisorError.updateFailed("Release v\(version) has no PKG asset")
            }

            let checksumAsset = release.assets.first(where: { $0.name.hasSuffix(".pkg.sha256") })

            return UpdateInfo(
                version: releaseVersion,
                pkgURL: pkgAsset.browserDownloadURL,
                checksumURL: checksumAsset?.browserDownloadURL,
                changelog: release.body ?? "",
                publishedAt: release.publishedAt ?? "",
                isPrerelease: release.prerelease,
            )
        }

        throw BarkVisorError.updateFailed("Version \(version) not found in \(channel.rawValue) channel")
    }

    // MARK: - Download and Install

    public func downloadAndInstall(
        release: UpdateInfo,
        progressHandler: @Sendable @escaping (Double) async -> Void,
    ) async throws {
        let updatesDir = Config.dataDir.appendingPathComponent("updates")
        try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let pkgPath = updatesDir.appendingPathComponent("BarkVisor-\(release.version).pkg")

        // Clean up any previous download
        try? FileManager.default.removeItem(at: pkgPath)

        // Download PKG
        guard let pkgURL = URL(string: release.pkgURL) else {
            throw BarkVisorError.updateFailed("Invalid PKG URL")
        }

        Log.server.info("Downloading update v\(release.version) from \(release.pkgURL)")
        await progressHandler(0.05)

        let (asyncBytes, response) = try await Self.session.bytes(from: pkgURL)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BarkVisorError.updateFailed("PKG download returned HTTP \(statusCode)")
        }
        let totalBytes = http.expectedContentLength

        let handle = try FileHandle(
            forWritingTo: {
                FileManager.default.createFile(atPath: pkgPath.path, contents: nil)
                return pkgPath
            }(),
        )
        defer { try? handle.close() }

        var bytesWritten: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(256 * 1_024)

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1_024 {
                handle.write(buffer)
                bytesWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if totalBytes > 0 {
                    let downloadProgress = Double(bytesWritten) / Double(totalBytes)
                    // Download is 0.05–0.80 of total progress
                    await progressHandler(0.05 + downloadProgress * 0.75)
                }
            }
        }
        if !buffer.isEmpty {
            handle.write(buffer)
            bytesWritten += Int64(buffer.count)
        }
        try handle.close()

        await progressHandler(0.80)
        Log.server.info("Download complete (\(bytesWritten) bytes), verifying checksum...")

        // Verify SHA256 checksum if available
        if let checksumURLStr = release.checksumURL, let checksumURL = URL(string: checksumURLStr) {
            let (checksumData, _) = try await Self.session.data(from: checksumURL)
            guard let checksumLine = String(data: checksumData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").first?.lowercased()
            else {
                throw BarkVisorError.updateFailed("Could not parse SHA256 checksum file")
            }

            let pkgData = try Data(contentsOf: pkgPath)
            let computedHash = SHA256.hash(data: pkgData)
                .compactMap { String(format: "%02x", $0) }
                .joined()

            guard computedHash == checksumLine else {
                try? FileManager.default.removeItem(at: pkgPath)
                throw BarkVisorError.updateFailed(
                    "SHA256 mismatch: expected \(checksumLine), got \(computedHash)",
                )
            }
            Log.server.info("SHA256 checksum verified")
        }

        await progressHandler(0.90)
        Log.server.info("Triggering PKG installation via privileged helper...")

        // Hand off to the privileged helper for signature verification + installation.
        // The helper replies before running the installer (which kills the daemon),
        // so we normally get a clean success. The 4097 catch is a safety net in case
        // the XPC reply doesn't flush before the postinstall script kills the daemon.
        do {
            try await HelperXPCClient.shared.installUpdate(
                packagePath: pkgPath.path,
                expectedVersion: release.version,
            )
        } catch let error as NSError
            where error.domain == "NSCocoaErrorDomain" && error.code == 4_097 {
            Log.server.info(
                "XPC connection lost during install (expected — postinstall restarts daemons)",
            )
        }

        await progressHandler(1.0)
    }

    // MARK: - Semver Comparison

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let splitA = a.split(separator: "-", maxSplits: 1)
        let splitB = b.split(separator: "-", maxSplits: 1)
        let partsA =
            splitA.first?
                .split(separator: ".").compactMap { Int($0) } ?? []
        let partsB =
            splitB.first?
                .split(separator: ".").compactMap { Int($0) } ?? []

        for i in 0 ..< max(partsA.count, partsB.count) {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va > vb }
        }

        // Per SemVer §11: a version without a prerelease has higher precedence than one with.
        let preA = splitA.count > 1 ? String(splitA[1]) : nil
        let preB = splitB.count > 1 ? String(splitB[1]) : nil

        switch (preA, preB) {
        case (nil, nil): return false
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(a), .some(b)): return a.compare(b, options: .numeric) == .orderedDescending
        }
    }
}
