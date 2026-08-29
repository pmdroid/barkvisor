#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Types

public struct UpdateInfo: Codable, Sendable, Equatable {
    public let version: String
    public let packageURL: String
    public let checksumURL: String
    public let packageKind: AppliancePackageKind
    public let changelog: String
    public let publishedAt: String
    public let isPrerelease: Bool

    public init(
        version: String,
        packageURL: String,
        checksumURL: String,
        packageKind: AppliancePackageKind,
        changelog: String,
        publishedAt: String,
        isPrerelease: Bool,
    ) {
        self.version = version
        self.packageURL = packageURL
        self.checksumURL = checksumURL
        self.packageKind = packageKind
        self.changelog = changelog
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
    }
}

public enum UpdateChannel: String, Codable, Sendable {
    case stable
    case beta
}

public struct PackageInstallPlan: Sendable, Equatable {
    public var installExecutable: String
    public var installArguments: [String]
    public var fixDependsExecutable: String?
    public var fixDependsArguments: [String]
    public var restartExecutable: String
    public var restartArguments: [String]

    public var commandLines: [String] {
        var lines = ["\(installExecutable) \(installArguments.joined(separator: " "))"]
        if let fix = fixDependsExecutable {
            lines.append("\(fix) \(fixDependsArguments.joined(separator: " "))")
        }
        lines.append("\(restartExecutable) \(restartArguments.joined(separator: " "))")
        return lines
    }

    public var mentionsBrew: Bool {
        commandLines.joined(separator: " ").localizedCaseInsensitiveContains("brew")
    }
}

public enum AppliancePackageInstaller {
    public static func plan(kind: AppliancePackageKind, packagePath: String) -> PackageInstallPlan {
        switch kind {
        case .deb:
            PackageInstallPlan(
                installExecutable: "/usr/bin/dpkg",
                installArguments: ["-i", packagePath],
                fixDependsExecutable: "/usr/bin/apt-get",
                fixDependsArguments: ["-f", "install", "-y"],
                restartExecutable: "/bin/systemctl",
                restartArguments: ["restart", "barkvisor.service"],
            )
        case .pkg:
            PackageInstallPlan(
                installExecutable: "/usr/sbin/installer",
                installArguments: ["-pkg", packagePath, "-target", "/"],
                fixDependsExecutable: nil,
                fixDependsArguments: [],
                restartExecutable: "/bin/launchctl",
                restartArguments: ["kickstart", "-k", "system/dev.barkvisor"],
            )
        }
    }

    public static func shouldFixDepends(exitCode: Int32, output: String) -> Bool {
        exitCode != 0 && output.lowercased().contains("depend")
    }
}

public enum UpdateChecksum {
    public static func parse(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = line.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = String(token).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

public enum UpdateReleaseParser {
    public struct Asset: Equatable, Sendable {
        public var name: String
        public var url: String

        public init(name: String, url: String) {
            self.name = name
            self.url = url
        }
    }

    public struct Release: Equatable, Sendable {
        public var tagName: String
        public var prerelease: Bool
        public var body: String
        public var publishedAt: String
        public var assets: [Asset]

        public init(
            tagName: String,
            prerelease: Bool,
            body: String,
            publishedAt: String,
            assets: [Asset],
        ) {
            self.tagName = tagName
            self.prerelease = prerelease
            self.body = body
            self.publishedAt = publishedAt
            self.assets = assets
        }

        public var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }
    }

    public static func decodeReleases(_ data: Data) throws -> [Release] {
        let decoded = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return decoded.map {
            Release(
                tagName: $0.tagName,
                prerelease: $0.prerelease,
                body: $0.body ?? "",
                publishedAt: $0.publishedAt ?? "",
                assets: $0.assets.map { Asset(name: $0.name, url: $0.browserDownloadURL) },
            )
        }
    }

    public static func pickPackage(
        assets: [Asset],
        kind: AppliancePackageKind,
        hostArch: String,
    ) -> (package: Asset, checksum: Asset)? {
        let package = assets.first { matches(name: $0.name, kind: kind, hostArch: hostArch) }
        guard let package else { return nil }
        let checksumName = package.name + ".sha256"
        guard let checksum = assets.first(where: { $0.name == checksumName }) else { return nil }
        return (package, checksum)
    }

    public static func pick(
        releases: [Release],
        channel: UpdateChannel,
        currentVersion: String,
        kind: AppliancePackageKind,
        hostArch: String,
        wantVersion: String? = nil,
    ) throws -> UpdateInfo? {
        let candidates: [Release] =
            switch channel {
            case .stable: releases.filter { !$0.prerelease }
            case .beta: releases
            }

        for release in candidates {
            if let wantVersion, release.version != wantVersion { continue }
            if wantVersion == nil, !UpdateService.isVersion(release.version, newerThan: currentVersion) {
                continue
            }
            guard let picked = pickPackage(assets: release.assets, kind: kind, hostArch: hostArch) else {
                if wantVersion != nil {
                    throw BarkVisorError.updateFailed(
                        "Release v\(release.version) has no \(kind.rawValue) asset with checksum for this Device",
                    )
                }
                continue
            }
            return UpdateInfo(
                version: release.version,
                packageURL: picked.package.url,
                checksumURL: picked.checksum.url,
                packageKind: kind,
                changelog: release.body,
                publishedAt: release.publishedAt,
                isPrerelease: release.prerelease,
            )
        }
        if let wantVersion {
            throw BarkVisorError.updateFailed(
                "Version \(wantVersion) not found in \(channel.rawValue) channel",
            )
        }
        return nil
    }

    public static func matches(name: String, kind: AppliancePackageKind, hostArch: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("homebrew") || lower.contains(".bottle") { return false }
        if lower.hasSuffix(".rpm") { return false }
        switch kind {
        case .deb:
            let arch = InAppUpdateEligibility.linuxDebArch(hostArch: hostArch)
            return lower.hasPrefix("barkvisor_") && lower.hasSuffix("_\(arch).deb")
        case .pkg:
            return name.hasSuffix(".pkg") && !name.hasSuffix(".pkg.sha256")
        }
    }
}

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

    private func resolvedURL(override: String?) -> String {
        if let override, !override.isEmpty { return override }
        return ProcessInfo.processInfo.environment["BARKVISOR_UPDATE_URL"]
            ?? Self.defaultReleasesURL
    }

    private func requiredKind() throws -> AppliancePackageKind {
        try PlatformCapabilities.requireInAppUpdate()
        let facts = InAppUpdateEligibility.liveFacts()
        guard let kind = InAppUpdateEligibility.packageKind(for: facts) else {
            throw BarkVisorError.unsupportedFeature(.inAppUpdate)
        }
        return kind
    }

    public func checkForUpdates(channel: UpdateChannel, urlOverride: String? = nil) async throws
        -> UpdateInfo? {
        let kind = try requiredKind()
        let releases = try await fetchReleases(urlOverride: urlOverride)
        return try UpdateReleaseParser.pick(
            releases: releases,
            channel: channel,
            currentVersion: Config.version,
            kind: kind,
            hostArch: PlatformCapabilities.hostArch,
        )
    }

    public func lookupRelease(version: String, channel: UpdateChannel, urlOverride: String? = nil)
        async throws -> UpdateInfo {
        let kind = try requiredKind()
        let releases = try await fetchReleases(urlOverride: urlOverride)
        guard let info = try UpdateReleaseParser.pick(
            releases: releases,
            channel: channel,
            currentVersion: Config.version,
            kind: kind,
            hostArch: PlatformCapabilities.hostArch,
            wantVersion: version,
        ) else {
            throw BarkVisorError.updateFailed("Version \(version) not found in \(channel.rawValue) channel")
        }
        return info
    }

    public func downloadAndInstall(
        release: UpdateInfo,
        progressHandler: @Sendable @escaping (Double) async -> Void,
        run: @Sendable (String, [String], TimeInterval?) throws -> CommandResult = {
            try PlatformProcess.run(path: $0, arguments: $1, timeout: $2)
        },
    ) async throws {
        try PlatformCapabilities.requireInAppUpdate()
        guard InAppUpdateEligibility.evaluate(InAppUpdateEligibility.liveFacts()) else {
            throw BarkVisorError.unsupportedFeature(.inAppUpdate)
        }

        let updatesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barkvisor-updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let ext = release.packageKind == .deb ? "deb" : "pkg"
        let packagePath = updatesDir.appendingPathComponent("BarkVisor-\(release.version).\(ext)")
        try? FileManager.default.removeItem(at: packagePath)

        guard let packageURL = URL(string: release.packageURL) else {
            throw BarkVisorError.updateFailed("Invalid package URL")
        }
        guard let checksumURL = URL(string: release.checksumURL) else {
            throw BarkVisorError.updateFailed("Invalid checksum URL")
        }

        Log.server.info("Downloading update v\(release.version) from \(release.packageURL)")
        await progressHandler(0.05)
        try await download(from: packageURL, to: packagePath, progressHandler: progressHandler)
        await progressHandler(0.80)

        let checksumData: Data
        do {
            let (data, response) = try await Self.session.data(from: checksumURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ... 299).contains(status) else {
                throw BarkVisorError.updateFailed("Checksum download returned HTTP \(status)")
            }
            checksumData = data
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw BarkVisorError.updateFailed("Checksum download failed")
        }

        guard let expected = UpdateChecksum.parse(String(data: checksumData, encoding: .utf8) ?? "")
        else {
            throw BarkVisorError.updateFailed("Could not parse SHA256 checksum file")
        }
        let computed = try ImageFileChecksum.sha256Hex(ofFile: packagePath)
        guard computed == expected else {
            try? FileManager.default.removeItem(at: packagePath)
            throw BarkVisorError.updateFailed(
                "SHA256 mismatch: expected \(expected), got \(computed)",
            )
        }
        Log.server.info("SHA256 checksum verified")
        await progressHandler(0.90)

        let plan = AppliancePackageInstaller.plan(
            kind: release.packageKind,
            packagePath: packagePath.path,
        )
        if plan.mentionsBrew {
            throw BarkVisorError.updateFailed("Refusing a brew install path")
        }

        let install = try run(plan.installExecutable, plan.installArguments, 600)
        if release.packageKind == .deb,
           AppliancePackageInstaller.shouldFixDepends(
               exitCode: install.exitCode,
               output: install.stdoutString + install.stderrString,
           ),
           let fixExe = plan.fixDependsExecutable {
            let fix = try run(fixExe, plan.fixDependsArguments, 300)
            guard fix.succeeded else {
                throw BarkVisorError.updateFailed("apt-get -f failed for declared Depends")
            }
        } else if !install.succeeded {
            let err = install.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BarkVisorError.updateFailed(
                err.isEmpty ? "Package install failed (exit \(install.exitCode))" : err,
            )
        }

        let restart = try run(plan.restartExecutable, plan.restartArguments, 60)
        if !restart.succeeded {
            Log.server.warning(
                "Update installed; restart returned \(restart.exitCode). The Device may still be coming back.",
            )
        }
        await progressHandler(1.0)
    }

    private func fetchReleases(urlOverride: String?) async throws -> [UpdateReleaseParser.Release] {
        let url = resolvedURL(override: urlOverride)
        guard let requestURL = URL(string: url) else {
            throw BarkVisorError.updateFailed("Invalid update URL: \(url)")
        }
        var request = URLRequest(url: requestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BarkVisor/\(Config.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ... 299).contains(statusCode) else {
            throw BarkVisorError.updateFailed("GitHub API returned HTTP \(statusCode)")
        }
        return try UpdateReleaseParser.decodeReleases(data)
    }

    private func download(
        from packageURL: URL,
        to packagePath: URL,
        progressHandler: @Sendable @escaping (Double) async -> Void,
    ) async throws {
        #if canImport(FoundationNetworking) && !canImport(Darwin)
            let (tempURL, response) = try await Self.session.download(from: packageURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ... 299).contains(statusCode) else {
                throw BarkVisorError.updateFailed("Package download returned HTTP \(statusCode)")
            }
            if FileManager.default.fileExists(atPath: packagePath.path) {
                try FileManager.default.removeItem(at: packagePath)
            }
            try FileManager.default.moveItem(at: tempURL, to: packagePath)
        #else
            let (asyncBytes, response) = try await Self.session.bytes(from: packageURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ... 299).contains(statusCode) else {
                throw BarkVisorError.updateFailed("Package download returned HTTP \(statusCode)")
            }
            let totalBytes = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
            FileManager.default.createFile(atPath: packagePath.path, contents: nil)
            let handle = try FileHandle(forWritingTo: packagePath)
            defer { try? handle.close() }
            var written: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(256 * 1_024)
            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= 256 * 1_024 {
                    handle.write(buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if totalBytes > 0 {
                        await progressHandler(0.05 + (Double(written) / Double(totalBytes)) * 0.75)
                    }
                }
            }
            if !buffer.isEmpty {
                handle.write(buffer)
            }
        #endif
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let splitA = a.split(separator: "-", maxSplits: 1)
        let splitB = b.split(separator: "-", maxSplits: 1)
        let partsA = splitA.first?.split(separator: ".").compactMap { Int($0) } ?? []
        let partsB = splitB.first?.split(separator: ".").compactMap { Int($0) } ?? []

        for i in 0 ..< max(partsA.count, partsB.count) {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va > vb }
        }

        let preA = splitA.count > 1 ? String(splitA[1]) : nil
        let preB = splitB.count > 1 ? String(splitB[1]) : nil
        switch (preA, preB) {
        case (nil, nil): return false
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(left), .some(right)):
            return left.compare(right, options: .numeric) == .orderedDescending
        }
    }
}
