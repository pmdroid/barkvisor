import Foundation

public struct ComposeImageFact: Equatable, Sendable {
    public var image: String
    public var digest: String?

    public init(image: String, digest: String? = nil) {
        self.image = image
        self.digest = digest
    }
}

struct ImageIdentities: Equatable {
    var config: String?
    var platformManifest: String?
    var index: String?
    var manifests: [String] = []

    var allManifests: Set<String> {
        var values = Set(manifests)
        if let platformManifest { values.insert(platformManifest) }
        if let index { values.insert(index) }
        return values
    }
}

struct ApplicationImageSnapshot: Equatable {
    var image: String
    var digest: String?
    var catalogDigest: String?
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

    static func updateAvailable(running: ImageIdentities, catalog: ImageIdentities) -> Bool {
        let pair = alignedDigests(running: running, catalog: catalog)
        return updateAvailable(running: pair.digest, catalog: pair.catalogDigest)
    }

    static func alignedDigests(
        running: ImageIdentities,
        catalog: ImageIdentities,
    ) -> (digest: String?, catalogDigest: String?) {
        if let platform = catalog.platformManifest, running.allManifests.contains(platform) {
            return (platform, platform)
        }
        if let index = catalog.index, running.allManifests.contains(index) {
            return (index, index)
        }
        for pin in catalog.manifests {
            if running.allManifests.contains(pin) || running.config == pin {
                return (pin, pin)
            }
        }
        if let runningConfig = running.config, catalog.allManifests.contains(runningConfig) {
            return (runningConfig, runningConfig)
        }
        if let runningConfig = running.config, let catalogConfig = catalog.config,
           runningConfig == catalogConfig {
            return (runningConfig, catalogConfig)
        }
        if let runningPlatform = running.platformManifest, let catalogPlatform = catalog.platformManifest {
            return (runningPlatform, catalogPlatform)
        }
        if let runningIndex = running.index, let catalogIndex = catalog.index {
            return (runningIndex, catalogIndex)
        }
        if let runningConfig = running.config, let catalogConfig = catalog.config {
            return (runningConfig, catalogConfig)
        }
        let preferred = running.platformManifest
            ?? running.manifests.first
            ?? running.index
            ?? running.config
        return (preferred, nil)
    }

    public static func parseInspect(_ json: String) -> [ComposeImageFact] {
        parseInspectRecords(json).map { record in
            ComposeImageFact(image: record.image, digest: record.identities.manifests.first)
        }
    }

    public static func parseRegistryDigest(
        _ json: String,
        os: String = "linux",
        arch: String? = nil,
    ) -> String? {
        let identities = parseRegistryIdentities(json, os: os, arch: arch)
        return identities.platformManifest
            ?? identities.index
            ?? identities.manifests.first
    }

    public static func running(
        id: String,
        project: String,
        dataDir: URL = Config.dataDir,
    ) throws -> [ComposeImageFact] {
        try runningRecords(id: id, project: project, dataDir: dataDir).map { record in
            ComposeImageFact(image: record.image, digest: record.identities.manifests.first)
        }
    }

    public static func registryDigest(for image: String) -> String? {
        let identities = registryIdentities(for: image)
        return identities.platformManifest
            ?? identities.index
            ?? identities.manifests.first
            ?? identities.config
    }

    static func snapshot(
        id: String,
        project: String,
        image: String?,
        dataDir: URL = Config.dataDir,
        os: String = "linux",
        arch: String? = nil,
    ) throws -> ApplicationImageSnapshot {
        let records = try runningRecords(id: id, project: project, dataDir: dataDir)
        let first = records.first
        let imageName = first?.image ?? image ?? ""
        let catalogImage = image ?? imageName
        if catalogImage.isEmpty {
            return ApplicationImageSnapshot(
                image: imageName,
                digest: first?.identities.manifests.first,
                catalogDigest: nil,
            )
        }
        let catalog = registryIdentities(for: catalogImage, os: os, arch: arch)
        if let first {
            let aligned = alignedDigests(running: first.identities, catalog: catalog)
            return ApplicationImageSnapshot(
                image: imageName,
                digest: aligned.digest,
                catalogDigest: aligned.catalogDigest,
            )
        }
        return ApplicationImageSnapshot(
            image: catalogImage,
            digest: nil,
            catalogDigest: catalog.platformManifest
                ?? catalog.index
                ?? catalog.manifests.first
                ?? catalog.config,
        )
    }

    static func identities(fromInspect json: String) -> ImageIdentities {
        parseInspectRecords(json).first?.identities ?? ImageIdentities()
    }

    static func identities(
        fromRegistry json: String,
        os: String = "linux",
        arch: String? = nil,
    ) -> ImageIdentities {
        parseRegistryIdentities(json, os: os, arch: arch)
    }

    static func dockerArch(_ hostArch: String) -> String {
        let normalized = PlatformCapabilities.normalizedArch(hostArch)
        if normalized == "x86_64" { return "amd64" }
        return normalized
    }

    private struct InspectRecord {
        var image: String
        var identities: ImageIdentities
    }

    private static func runningRecords(
        id: String,
        project: String,
        dataDir: URL,
    ) throws -> [InspectRecord] {
        let ids = try ComposeRuntime.containerIDs(id: id, project: project, dataDir: dataDir)
        if ids.isEmpty { return [] }
        let result = try DockerCLI.run(
            arguments: ["inspect"] + ids,
            timeout: 20,
        )
        if !result.succeeded { return [] }
        let containers = parseInspectRecords(result.stdoutString)
        let imageRefs = uniqueImageRefs(containers)
        if imageRefs.isEmpty { return containers }
        guard let imageResult = try? DockerCLI.run(
            arguments: ["inspect"] + imageRefs,
            timeout: 20,
        ), imageResult.succeeded else {
            return containers
        }
        let images = parseInspectRecords(imageResult.stdoutString)
        return mergeInspectRecords(containers, images: images)
    }

    private static func uniqueImageRefs(_ records: [InspectRecord]) -> [String] {
        var seen = Set<String>()
        var refs: [String] = []
        for record in records {
            var candidates: [String] = []
            if let config = record.identities.config {
                let trimmed = config.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { candidates.append(trimmed) }
            }
            let image = record.image.trimmingCharacters(in: .whitespacesAndNewlines)
            if !image.isEmpty { candidates.append(image) }
            for candidate in candidates where seen.insert(candidate).inserted {
                refs.append(candidate)
                break
            }
        }
        return refs
    }

    private static func mergeInspectRecords(
        _ containers: [InspectRecord],
        images: [InspectRecord],
    ) -> [InspectRecord] {
        containers.map { container in
            var merged = container
            let match = images.first { image in
                if let containerConfig = container.identities.config,
                   let imageConfig = image.identities.config,
                   containerConfig == imageConfig {
                    return true
                }
                if !container.image.isEmpty, container.image == image.image {
                    return true
                }
                return false
            }
            guard let match else { return merged }
            if merged.image.isEmpty || isBareImageID(merged.image) {
                merged.image = match.image
            }
            if let imageConfig = match.identities.config {
                merged.identities.config = imageConfig
            }
            merged.identities.manifests = match.identities.manifests
            merged.identities.platformManifest = match.identities.platformManifest
            merged.identities.index = match.identities.index
            return merged
        }
    }

    private static func registryIdentities(
        for image: String,
        os: String = "linux",
        arch: String? = nil,
    ) -> ImageIdentities {
        let trimmed = image.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ImageIdentities() }
        let pin: String? = trimmed.contains("@") ? normalizeDigest(trimmed) : nil
        if let result = try? DockerCLI.run(
            arguments: ["manifest", "inspect", "--verbose", trimmed],
            timeout: 30,
        ), result.succeeded {
            var identities = parseRegistryIdentities(result.stdoutString, os: os, arch: arch)
            if identities.platformManifest == nil,
               identities.index == nil,
               identities.manifests.isEmpty,
               identities.config == nil,
               let pin {
                identities.manifests = [pin]
            }
            return identities
        }
        if let pin {
            return ImageIdentities(manifests: [pin])
        }
        return ImageIdentities()
    }

    private static func parseInspectRecords(_ json: String) -> [InspectRecord] {
        inspectBlobs(json).compactMap { parseInspectObject($0) }
    }

    private static func parseInspectObject(_ object: [String: Any]) -> InspectRecord? {
        let hasImageFields = object["RepoDigests"] != nil || object["RepoTags"] != nil
        if hasImageFields {
            return parseImageInspectObject(object)
        }
        return parseContainerInspectObject(object)
    }

    private static func parseContainerInspectObject(_ object: [String: Any]) -> InspectRecord? {
        var identities = ImageIdentities()
        if let imageID = object["Image"] as? String, isDigestString(imageID) {
            identities.config = normalizeDigest(imageID)
        }
        let image = inspectImageName(object)
        if image.isEmpty, identities.config == nil { return nil }
        return InspectRecord(image: image, identities: identities)
    }

    private static func parseImageInspectObject(_ object: [String: Any]) -> InspectRecord? {
        var identities = ImageIdentities()
        if let id = object["Id"] as? String, isDigestString(id) {
            identities.config = normalizeDigest(id)
        }
        if let repos = object["RepoDigests"] as? [String] {
            identities.manifests = repos.compactMap { repo in
                guard repo.contains("@") else { return nil }
                let digest = normalizeDigest(repo)
                return digest.isEmpty ? nil : digest
            }
        }
        let image = inspectImageName(object)
        if image.isEmpty, identities.config == nil, identities.manifests.isEmpty { return nil }
        return InspectRecord(image: image, identities: identities)
    }

    private static func inspectImageName(_ object: [String: Any]) -> String {
        if let tags = object["RepoTags"] as? [String] {
            if let tag = tags.first(where: { !isBareImageID($0) && !$0.isEmpty }) {
                return tag
            }
        }
        if let config = object["Config"] as? [String: Any],
           let image = config["Image"] as? String,
           !image.isEmpty,
           !isBareImageID(image) {
            return image
        }
        if let repos = object["RepoDigests"] as? [String], let repo = repos.first, !repo.isEmpty {
            if let at = repo.lastIndex(of: "@") {
                return String(repo[..<at])
            }
            return repo
        }
        return ""
    }

    private static func parseRegistryIdentities(
        _ json: String,
        os: String = "linux",
        arch: String? = nil,
    ) -> ImageIdentities {
        let resolvedArch = arch ?? dockerArch(PlatformCapabilities.hostArch)
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ImageIdentities() }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return ImageIdentities() }
        if let array = object as? [Any] {
            return parseRegistryList(array, os: os, arch: resolvedArch)
        }
        guard let dict = object as? [String: Any] else { return ImageIdentities() }
        return parseRegistryObject(dict, os: os, arch: resolvedArch)
    }

    private static func parseRegistryList(_ blobs: [Any], os: String, arch: String) -> ImageIdentities {
        var identities = ImageIdentities()
        var unmatched: [String] = []
        for blob in blobs {
            guard let dict = blob as? [String: Any] else { continue }
            let parsed = parseRegistryObject(dict, os: os, arch: arch)
            if let index = parsed.index, identities.index == nil {
                identities.index = index
            }
            if let platform = parsed.platformManifest {
                if identities.platformManifest == nil {
                    identities.platformManifest = platform
                }
                if identities.config == nil {
                    identities.config = parsed.config
                }
            }
            unmatched.append(contentsOf: parsed.manifests)
        }
        if identities.platformManifest == nil, identities.index == nil, identities.config == nil {
            identities.manifests = unmatched
        }
        return identities
    }

    private static func parseRegistryObject(
        _ object: [String: Any],
        os: String,
        arch: String,
    ) -> ImageIdentities {
        var identities = ImageIdentities()
        if let manifests = object["manifests"] as? [[String: Any]] {
            if let digest = object["digest"] as? String, isDigestString(digest) {
                identities.index = normalizeDigest(digest)
            } else if isIndexMediaType(object["mediaType"] as? String),
                      let digest = descriptorDigestValue(object) {
                identities.index = digest
            }
            for entry in manifests {
                guard platformMatches(entry["platform"] as? [String: Any], os: os, arch: arch) else {
                    continue
                }
                if let digest = entry["digest"] as? String, isDigestString(digest) {
                    identities.platformManifest = normalizeDigest(digest)
                    break
                }
            }
        }
        applyDescriptor(&identities, object: object, os: os, arch: arch)
        if identities.config == nil {
            identities.config = nestedConfigDigest(object)
        }
        if identities.platformManifest == nil,
           identities.index == nil,
           identities.manifests.isEmpty,
           let digest = object["digest"] as? String,
           isDigestString(digest) {
            identities.manifests = [normalizeDigest(digest)]
        }
        return identities
    }

    private static func applyDescriptor(
        _ identities: inout ImageIdentities,
        object: [String: Any],
        os: String,
        arch: String,
    ) {
        let descriptor = object["Descriptor"] as? [String: Any]
        guard let digest = descriptorDigestValue(descriptor ?? object) else { return }
        let mediaType = (descriptor?["mediaType"] as? String) ?? (object["mediaType"] as? String)
        let platform = (descriptor?["platform"] as? [String: Any])
            ?? (object["Platform"] as? [String: Any])
            ?? (object["platform"] as? [String: Any])
        if isIndexMediaType(mediaType) {
            if identities.index == nil { identities.index = digest }
            return
        }
        if platform == nil || platformMatches(platform, os: os, arch: arch) {
            if identities.platformManifest == nil { identities.platformManifest = digest }
            return
        }
        identities.manifests.append(digest)
    }

    private static func nestedConfigDigest(_ object: [String: Any]) -> String? {
        for key in ["SchemaV2Manifest", "OCIManifest"] {
            guard let manifest = object[key] as? [String: Any],
                  let config = manifest["config"] as? [String: Any],
                  let digest = config["digest"] as? String,
                  isDigestString(digest)
            else { continue }
            return normalizeDigest(digest)
        }
        return nil
    }

    private static func descriptorDigestValue(_ object: [String: Any]) -> String? {
        if let digest = object["digest"] as? String, isDigestString(digest) {
            return normalizeDigest(digest)
        }
        if let digest = object["Digest"] as? String, isDigestString(digest) {
            return normalizeDigest(digest)
        }
        return nil
    }

    private static func inspectBlobs(_ json: String) -> [[String: Any]] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        if let array = object as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        if let dict = object as? [String: Any] {
            return [dict]
        }
        return []
    }

    private static func isDigestString(_ raw: String) -> Bool {
        normalizeDigest(raw).hasPrefix("sha256:")
    }

    private static func isBareImageID(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") || trimmed.contains("@") { return false }
        return trimmed.lowercased().hasPrefix("sha256:")
    }

    private static func isIndexMediaType(_ raw: String?) -> Bool {
        let value = (raw ?? "").lowercased()
        return value.contains("image.index") || value.contains("manifest.list")
    }

    private static func platformMatches(_ platform: [String: Any]?, os: String, arch: String) -> Bool {
        guard let platform else { return false }
        let platformOS = (platform["os"] as? String ?? "").lowercased()
        let platformArch = (platform["architecture"] as? String ?? "").lowercased()
        let wantOS = os.lowercased()
        let wantArch = dockerArch(arch).lowercased()
        if platformArch.isEmpty { return false }
        if platformArch == "unknown" { return false }
        if !platformOS.isEmpty, platformOS != wantOS, platformOS != "unknown" { return false }
        return platformArch == wantArch || dockerArch(platformArch) == wantArch
    }
}
