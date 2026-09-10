import Foundation

public struct ComposeImageFact: Equatable, Sendable {
    public var image: String
    public var digest: String?

    public init(image: String, digest: String? = nil) {
        self.image = image
        self.digest = digest
    }
}

public enum ApplicationImageFacts {
    public static func normalizeDigest(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = value.lastIndex(of: "@") {
            value = String(value[value.index(after: at)...])
        }
        return value.lowercased()
    }

    public static func updateAvailable(running: String?, catalog: String?) -> Bool {
        guard let running, let catalog else { return false }
        let a = normalizeDigest(running)
        let b = normalizeDigest(catalog)
        if a.isEmpty || b.isEmpty { return false }
        return a != b
    }

    public static func parseInspect(_ json: String) -> [ComposeImageFact] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var blobs: [Any] = []
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let array = object as? [Any] {
                blobs = array
            } else {
                blobs = [object]
            }
        }
        var facts: [ComposeImageFact] = []
        for blob in blobs {
            guard let object = blob as? [String: Any] else { continue }
            let image = inspectImage(object)
            if image.isEmpty { continue }
            facts.append(ComposeImageFact(image: image, digest: inspectDigest(object)))
        }
        return facts
    }

    public static func parseRegistryDigest(
        _ json: String,
        os: String = "linux",
        arch: String? = nil,
    ) -> String? {
        let resolvedArch = arch ?? dockerArch(PlatformCapabilities.hostArch)
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        if let array = object as? [Any] {
            let platform = platformDigest(in: array, os: os, arch: resolvedArch)
            if platform != nil { return platform }
            for item in array {
                if let dict = item as? [String: Any],
                   let digest = descriptorDigest(dict, os: os, arch: resolvedArch, requirePlatform: false) {
                    return digest
                }
            }
            return nil
        }
        guard let dict = object as? [String: Any] else { return nil }
        if let fromList = manifestListDigest(dict, os: os, arch: resolvedArch) {
            return fromList
        }
        return descriptorDigest(dict, os: os, arch: resolvedArch, requirePlatform: false)
    }

    public static func running(
        id: String,
        project: String,
        dataDir: URL = Config.dataDir,
    ) throws -> [ComposeImageFact] {
        let ids = try ComposeRuntime.containerIDs(id: id, project: project, dataDir: dataDir)
        if ids.isEmpty { return [] }
        let result = try DockerCLI.run(
            arguments: ["inspect"] + ids,
            timeout: 20,
        )
        if !result.succeeded { return [] }
        return parseInspect(result.stdoutString)
    }

    public static func registryDigest(for image: String) -> String? {
        let trimmed = image.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains("@") {
            return normalizeDigest(trimmed)
        }
        guard let result = try? DockerCLI.run(
            arguments: ["manifest", "inspect", "--verbose", trimmed],
            timeout: 30,
        ), result.succeeded else { return nil }
        return parseRegistryDigest(result.stdoutString)
    }

    static func dockerArch(_ hostArch: String) -> String {
        let normalized = PlatformCapabilities.normalizedArch(hostArch)
        if normalized == "x86_64" { return "amd64" }
        return normalized
    }

    private static func inspectImage(_ object: [String: Any]) -> String {
        if let config = object["Config"] as? [String: Any],
           let image = config["Image"] as? String,
           !image.isEmpty {
            return image
        }
        if let repo = (object["RepoDigests"] as? [String])?.first, !repo.isEmpty {
            if let at = repo.lastIndex(of: "@") {
                return String(repo[..<at])
            }
            return repo
        }
        return (object["Image"] as? String) ?? ""
    }

    private static func inspectDigest(_ object: [String: Any]) -> String? {
        if let repos = object["RepoDigests"] as? [String] {
            for repo in repos where repo.contains("@") {
                return normalizeDigest(repo)
            }
        }
        if let image = object["Image"] as? String, image.lowercased().hasPrefix("sha256:") {
            return normalizeDigest(image)
        }
        return nil
    }

    private static func manifestListDigest(_ object: [String: Any], os: String, arch: String) -> String? {
        guard let manifests = object["manifests"] as? [[String: Any]] else { return nil }
        for entry in manifests {
            if platformMatches(entry["platform"] as? [String: Any], os: os, arch: arch),
               let digest = entry["digest"] as? String {
                return normalizeDigest(digest)
            }
        }
        return nil
    }

    private static func platformDigest(in blobs: [Any], os: String, arch: String) -> String? {
        for blob in blobs {
            guard let dict = blob as? [String: Any] else { continue }
            if let digest = descriptorDigest(dict, os: os, arch: arch, requirePlatform: true) {
                return digest
            }
        }
        return nil
    }

    private static func descriptorDigest(
        _ object: [String: Any],
        os: String,
        arch: String,
        requirePlatform: Bool,
    ) -> String? {
        if let descriptor = object["Descriptor"] as? [String: Any] {
            let platform = descriptor["platform"] as? [String: Any]
            if requirePlatform {
                guard platformMatches(platform, os: os, arch: arch) else { return nil }
            } else if let platform, !platformMatches(platform, os: os, arch: arch) {
                return nil
            }
            if let digest = descriptor["digest"] as? String {
                return normalizeDigest(digest)
            }
        }
        if let digest = object["digest"] as? String, digest.lowercased().hasPrefix("sha256:") {
            return normalizeDigest(digest)
        }
        return nil
    }

    private static func platformMatches(_ platform: [String: Any]?, os: String, arch: String) -> Bool {
        guard let platform else { return false }
        let platformOS = (platform["os"] as? String ?? "").lowercased()
        let platformArch = (platform["architecture"] as? String ?? "").lowercased()
        let wantOS = os.lowercased()
        let wantArch = dockerArch(arch).lowercased()
        if !platformOS.isEmpty, platformOS != wantOS { return false }
        if platformArch.isEmpty { return false }
        return platformArch == wantArch || dockerArch(platformArch) == wantArch
    }
}
