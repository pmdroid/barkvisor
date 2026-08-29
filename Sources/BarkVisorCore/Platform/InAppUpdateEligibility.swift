import Foundation

#if os(macOS)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Package the root Device daemon may apply from Settings → Updates.
public enum AppliancePackageKind: String, Sendable, Codable, Equatable {
    case deb
    case pkg
}

/// Host facts for in-app updates. Injected in tests; `liveFacts()` reads this process.
public struct InAppUpdateFacts: Sendable, Equatable {
    public var isRoot: Bool
    public var isInstalledLayout: Bool
    public var dataDirIsVarLib: Bool
    public var dataDirOverridden: Bool
    public var hostArch: String
    public var os: String
    public var installPrefix: String
    public var executablePath: String
    public var debianFamily: Bool
    public var dpkgPresent: Bool

    public init(
        isRoot: Bool,
        isInstalledLayout: Bool,
        dataDirIsVarLib: Bool,
        dataDirOverridden: Bool,
        hostArch: String,
        os: String,
        installPrefix: String,
        executablePath: String,
        debianFamily: Bool,
        dpkgPresent: Bool,
    ) {
        self.isRoot = isRoot
        self.isInstalledLayout = isInstalledLayout
        self.dataDirIsVarLib = dataDirIsVarLib
        self.dataDirOverridden = dataDirOverridden
        self.hostArch = hostArch
        self.os = os
        self.installPrefix = installPrefix
        self.executablePath = executablePath
        self.debianFamily = debianFamily
        self.dpkgPresent = dpkgPresent
    }
}

/// True only for a root appliance with the known `/var/lib/barkvisor` layout.
///
/// False for `swift run`, smoke (`BARKVISOR_DATA_DIR`), Homebrew kegs, Fedora/rpm,
/// Intel Mac, and Windows. Ubuntu/Debian apply a `.deb`; Apple Silicon applies a `.pkg`.
public enum InAppUpdateEligibility {
    public static let applianceDataDir = "/var/lib/barkvisor"

    public static func evaluate(_ facts: InAppUpdateFacts) -> Bool {
        packageKind(for: facts) != nil
    }

    public static func packageKind(for facts: InAppUpdateFacts) -> AppliancePackageKind? {
        guard facts.isRoot else { return nil }
        guard facts.isInstalledLayout else { return nil }
        guard facts.dataDirIsVarLib else { return nil }
        guard !facts.dataDirOverridden else { return nil }
        guard !isHomebrewKeg(prefix: facts.installPrefix, executablePath: facts.executablePath)
        else { return nil }

        let arch = PlatformCapabilities.normalizedArch(facts.hostArch)
        let os = facts.os.lowercased()
        if os == "linux" {
            guard facts.debianFamily, facts.dpkgPresent else { return nil }
            return .deb
        }
        if os == "macos" || os == "darwin" {
            guard arch == "arm64" else { return nil }
            return .pkg
        }
        return nil
    }

    public static func isHomebrewKeg(prefix: String, executablePath: String) -> Bool {
        let prefixPath = URL(fileURLWithPath: prefix).standardizedFileURL.path
        let exe = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        if prefixPath == "/opt/homebrew" || prefixPath.hasPrefix("/opt/homebrew/") {
            return true
        }
        if exe.hasPrefix("/opt/homebrew/") { return true }
        return exe.contains("/Cellar/")
    }

    public static func isDebianFamily(osRelease: String) -> Bool {
        var id = ""
        var idLike = ""
        for rawLine in osRelease.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "ID": id = value.lowercased()
            case "ID_LIKE": idLike = value.lowercased()
            default: break
            }
        }
        if id == "ubuntu" || id == "debian" { return true }
        return idLike.split(whereSeparator: \.isWhitespace).contains { $0 == "debian" }
    }

    public static func isApplianceDataDir(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == applianceDataDir || standardized == "/private/var/lib/barkvisor"
    }

    public static func linuxDebArch(hostArch: String) -> String {
        PlatformCapabilities.normalizedArch(hostArch) == "arm64" ? "arm64" : "amd64"
    }

    public static func liveFacts(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        osRelease: String? = nil,
    ) -> InAppUpdateFacts {
        let argument = ProcessInfo.processInfo.arguments[0]
        let exe = PlatformPaths.resolvedExecutablePath(
            argument: argument,
            pathEnvironment: environment["PATH"],
            currentDirectory: FileManager.default.currentDirectoryPath,
            isExecutable: fileExists,
        )
        let prefix = PlatformPaths.installPrefix(executablePath: exe)
        let binDir = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()
        let override = environment["BARKVISOR_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let releaseText = osRelease ?? (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? ""
        return InAppUpdateFacts(
            isRoot: WorkloadPrivilegeDrop.currentEUID() == 0,
            isInstalledLayout: PlatformPaths.isInstalled(
                prefix: prefix,
                binaryDirectoryIsBin: binDir.lastPathComponent == "bin",
            ),
            dataDirIsVarLib: isApplianceDataDir(Config.dataDir.path),
            dataDirOverridden: !override.isEmpty,
            hostArch: PlatformCapabilities.hostArch,
            os: PlatformHost.platformName,
            installPrefix: prefix,
            executablePath: exe,
            debianFamily: isDebianFamily(osRelease: releaseText),
            dpkgPresent: fileExists("/usr/bin/dpkg"),
        )
    }
}
