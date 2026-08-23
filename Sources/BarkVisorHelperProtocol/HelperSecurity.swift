import Foundation

/// LaunchDaemon user/group for the BarkVisor service process.
public let kHelperServiceUser = "_barkvisor"

/// Bridged `socket_vmnet` sockets are group-accessible to the service account, not world-writable.
public let kHelperBridgeSocketMode = 0o660

/// Code-signing identifier for bundled `socket_vmnet` (set at release sign time).
public let kHelperSocketVmnetIdentifier = "socket_vmnet"

/// PKG identifier used by `pkgbuild` / `productbuild` in `scripts/build-release.sh`.
public let kHelperPackageIdentifier = "dev.barkvisor"

/// Code-signing identifier of the Device daemon (XPC client).
public let kHelperClientIdentifier = "dev.barkvisor.app"

/// Root-owned directory the helper copies update PKGs into before verification.
public let kHelperUpdateStagingDir = "/var/db/barkvisor-helper/updates"

public func helperCodeRequirement(identifier: String, teamID: String) -> String {
    "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
}

/// Identifier-only requirement used after Team ID fails (Homebrew ad-hoc).
public func helperClientIdentifierRequirement(identifier: String = kHelperClientIdentifier) -> String {
    "identifier \"\(identifier)\""
}

public func helperHomebrewPrefixes(extraPrefix: String? = nil) -> [String] {
    var prefixes = ["/opt/homebrew", "/usr/local"]
    if let extra = extraPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
       !extra.isEmpty,
       !prefixes.contains(extra) {
        prefixes.insert(extra, at: 0)
    }
    return prefixes
}

public func helperClientPathIsHomebrewBarkVisor(_ path: String, prefixes: [String]) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    let name = URL(fileURLWithPath: resolved).lastPathComponent
    guard name == "barkvisor" || name == "BarkVisorApp" else { return false }
    return prefixes.contains { prefix in
        let p = URL(fileURLWithPath: prefix).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == p || resolved.hasPrefix(p + "/")
    }
}

/// Release SMJobBless stays Team ID. Homebrew keg clients are ad-hoc and
/// accepted only when the executable lives under a Homebrew prefix.
public func helperAllowsXPCClient(
    identifier: String?,
    teamID: String?,
    isAdHoc: Bool,
    executablePath: String?,
    homebrewPrefixes: [String] = helperHomebrewPrefixes(),
) -> Bool {
    guard identifier == kHelperClientIdentifier else { return false }
    if teamID == kHelperTeamID {
        return true
    }
    guard isAdHoc,
          let executablePath,
          helperClientPathIsHomebrewBarkVisor(executablePath, prefixes: homebrewPrefixes)
    else {
        return false
    }
    return true
}

public func helperSigningIsAdHoc(teamID: String?, flags: UInt32 = 0) -> Bool {
    let csAdhoc: UInt32 = 0x0000_0002
    if flags & csAdhoc != 0 { return true }
    return teamID == nil || teamID?.isEmpty == true
}

public func helperNormalizedVersion(_ version: String) -> String {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.first == "v" || trimmed.first == "V" {
        return String(trimmed.dropFirst())
    }
    return trimmed
}

public func helperIsSafeExpectedVersion(_ version: String) -> Bool {
    let normalized = helperNormalizedVersion(version)
    guard !normalized.isEmpty, normalized.count <= 64 else { return false }
    return normalized.unicodeScalars.allSatisfy { scalar in
        CharacterSet.alphanumerics.contains(scalar)
            || scalar == "."
            || scalar == "-"
            || scalar == "+"
    }
}

public func helperVersionsMatch(expected: String, package: String) -> Bool {
    let expectedNormalized = helperNormalizedVersion(expected)
    let packageNormalized = helperNormalizedVersion(package)
    return !expectedNormalized.isEmpty && expectedNormalized == packageNormalized
}

public func helperTeamIDFromPkgutilOutput(_ output: String) -> String? {
    for line in output.components(separatedBy: .newlines) where line.contains("Developer ID Installer:") {
        if let teamID = firstParenthesizedTeamID(in: line) {
            return teamID
        }
    }
    return firstParenthesizedTeamID(in: output)
}

public func helperParsePackageVersion(fromXML xml: String) -> String? {
    guard let data = xml.data(using: .utf8) else { return nil }
    let parser = XMLParser(data: data)
    let delegate = PackageVersionXMLParser(preferredIdentifier: kHelperPackageIdentifier)
    parser.delegate = delegate
    guard parser.parse() else { return nil }
    return delegate.version
}

public func helperParsePackageVersion(fromExpandedRoot root: String) -> String? {
    let fm = FileManager.default
    var xmlPaths: [String] = []
    let distribution = (root as NSString).appendingPathComponent("Distribution")
    if fm.fileExists(atPath: distribution) {
        xmlPaths.append(distribution)
    }
    let packageInfo = (root as NSString).appendingPathComponent("PackageInfo")
    if fm.fileExists(atPath: packageInfo) {
        xmlPaths.append(packageInfo)
    }
    if let items = try? fm.contentsOfDirectory(atPath: root) {
        for item in items where item.hasSuffix(".pkg") {
            let nested = (root as NSString).appendingPathComponent(item)
            let nestedInfo = (nested as NSString).appendingPathComponent("PackageInfo")
            if fm.fileExists(atPath: nestedInfo) {
                xmlPaths.append(nestedInfo)
            }
        }
    }
    for xmlPath in xmlPaths {
        guard let xml = try? String(contentsOfFile: xmlPath, encoding: .utf8),
              let version = helperParsePackageVersion(fromXML: xml)
        else { continue }
        return version
    }
    return nil
}

private func firstParenthesizedTeamID(in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: "\\(([A-Z0-9]+)\\)") else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let capture = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[capture])
}

private final class PackageVersionXMLParser: NSObject, XMLParserDelegate {
    private let preferredIdentifier: String
    private var preferredVersion: String?
    private var fallbackVersion: String?

    init(preferredIdentifier: String) {
        self.preferredIdentifier = preferredIdentifier
    }

    var version: String? {
        preferredVersion ?? fallbackVersion
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:],
    ) {
        guard let version = attributeDict["version"], !version.isEmpty else { return }

        switch elementName {
        case "pkg-ref":
            let id = attributeDict["id"]
            if id == preferredIdentifier {
                preferredVersion = version
            } else if fallbackVersion == nil {
                fallbackVersion = version
            }
        case "pkg-info":
            let identifier = attributeDict["identifier"] ?? attributeDict["id"]
            if identifier == preferredIdentifier {
                preferredVersion = version
            } else if fallbackVersion == nil {
                fallbackVersion = version
            }
        default:
            break
        }
    }
}
