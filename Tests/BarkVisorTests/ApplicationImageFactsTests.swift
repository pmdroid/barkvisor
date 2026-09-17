import Foundation
import Testing
@testable import BarkVisorCore

struct ApplicationImageFactsTests {
    @Test func `container inspect does not treat image id as a repo digest`() {
        let json = """
        [{"Id":"0123456789abcdef","Image":"sha256:configcccc",\
        "Config":{"Image":"lscr.io/linuxserver/qbittorrent:latest"},\
        "State":{"Running":true}}]
        """
        let facts = ApplicationImageFacts.parseInspect(json)
        #expect(facts.count == 1)
        #expect(facts[0].image == "lscr.io/linuxserver/qbittorrent:latest")
        #expect(facts[0].digest == nil)
        let identities = ApplicationImageFacts.identities(fromInspect: json)
        #expect(identities.config == "sha256:configcccc")
        #expect(identities.manifests.isEmpty)
    }

    @Test func `image inspect yields repo digest not config id`() {
        let json = """
        [{"Id":"sha256:configcccc","RepoTags":["lscr.io/linuxserver/qbittorrent:latest"],\
        "RepoDigests":["lscr.io/linuxserver/qbittorrent@sha256:platformbbbb"],\
        "Architecture":"arm64","Os":"linux"}]
        """
        let facts = ApplicationImageFacts.parseInspect(json)
        #expect(facts.count == 1)
        #expect(facts[0].image == "lscr.io/linuxserver/qbittorrent:latest")
        #expect(facts[0].digest == "sha256:platformbbbb")
        let identities = ApplicationImageFacts.identities(fromInspect: json)
        #expect(identities.config == "sha256:configcccc")
        #expect(identities.manifests == ["sha256:platformbbbb"])
    }

    @Test func `registry verbose manifest yields descriptor digest`() {
        let json = """
        {"Descriptor":{"digest":"sha256:BBB222CCC333","mediaType":"application/vnd.oci.image.manifest.v1+json"}}
        """
        #expect(ApplicationImageFacts.parseRegistryDigest(json) == "sha256:bbb222ccc333")
    }

    @Test func `registry list uses the platform manifest not the index or config`() {
        let json = """
        [{"Descriptor":{"digest":"sha256:indexaaaa","mediaType":"application/vnd.oci.image.index.v1+json",\
        "platform":{"architecture":"unknown","os":"linux"}},\
        "SchemaV2Manifest":{"config":{"digest":"sha256:configcccc"}}},\
        {"Descriptor":{"digest":"sha256:platformbbbb","mediaType":"application/vnd.oci.image.manifest.v1+json",\
        "platform":{"architecture":"arm64","os":"linux"}},\
        "SchemaV2Manifest":{"config":{"digest":"sha256:configcccc"}}}]
        """
        let digest = ApplicationImageFacts.parseRegistryDigest(json, os: "linux", arch: "arm64")
        #expect(digest == "sha256:platformbbbb")
        let catalog = ApplicationImageFacts.identities(fromRegistry: json, os: "linux", arch: "arm64")
        #expect(catalog.platformManifest == "sha256:platformbbbb")
        #expect(catalog.index == "sha256:indexaaaa")
        #expect(catalog.config == "sha256:configcccc")
        #expect(
            !ApplicationImageFacts.updateAvailable(
                running: "sha256:platformbbbb",
                catalog: digest,
            ),
        )
        #expect(
            ApplicationImageFacts.updateAvailable(
                running: "sha256:platformbbbb",
                catalog: "sha256:indexaaaa",
            ),
        )
    }

    @Test func `same image config and platform identities are not an update`() {
        let running = ImageIdentities(
            config: "sha256:configcccc",
            manifests: ["sha256:platformbbbb"],
        )
        let catalog = ImageIdentities(
            config: "sha256:configcccc",
            platformManifest: "sha256:platformbbbb",
            index: "sha256:indexaaaa",
        )
        #expect(!ApplicationImageFacts.updateAvailable(running: running, catalog: catalog))
        let aligned = ApplicationImageFacts.alignedDigests(running: running, catalog: catalog)
        #expect(aligned.digest == aligned.catalogDigest)
        #expect(aligned.digest != nil)
    }

    @Test func `container config is not compared to registry platform manifest`() {
        let running = ImageIdentities(config: "sha256:configcccc")
        let catalog = ImageIdentities(
            platformManifest: "sha256:platformbbbb",
            index: "sha256:indexaaaa",
        )
        #expect(!ApplicationImageFacts.updateAvailable(running: running, catalog: catalog))
        let aligned = ApplicationImageFacts.alignedDigests(running: running, catalog: catalog)
        #expect(aligned.catalogDigest == nil)
    }

    @Test func `matching config identities align when repo digests are missing`() {
        let running = ImageIdentities(config: "sha256:configcccc")
        let catalog = ImageIdentities(
            config: "sha256:configcccc",
            platformManifest: "sha256:platformbbbb",
        )
        #expect(!ApplicationImageFacts.updateAvailable(running: running, catalog: catalog))
        let aligned = ApplicationImageFacts.alignedDigests(running: running, catalog: catalog)
        #expect(aligned.digest == "sha256:configcccc")
        #expect(aligned.catalogDigest == "sha256:configcccc")
    }

    @Test func `changed content reports an update on the same digest kind`() {
        let running = ImageIdentities(
            config: "sha256:configold",
            manifests: ["sha256:platformold"],
        )
        let catalog = ImageIdentities(
            config: "sha256:confignew",
            platformManifest: "sha256:platformnew",
        )
        #expect(ApplicationImageFacts.updateAvailable(running: running, catalog: catalog))
        let aligned = ApplicationImageFacts.alignedDigests(running: running, catalog: catalog)
        #expect(aligned.digest == "sha256:configold")
        #expect(aligned.catalogDigest == "sha256:confignew")
    }

    @Test func `index digest is not an update against the matching platform image`() {
        let running = ImageIdentities(
            config: "sha256:configcccc",
            manifests: ["sha256:indexaaaa"],
        )
        let catalog = ImageIdentities(
            config: "sha256:configcccc",
            platformManifest: "sha256:platformbbbb",
            index: "sha256:indexaaaa",
        )
        #expect(!ApplicationImageFacts.updateAvailable(running: running, catalog: catalog))
    }

    @Test func `digest pin matches repo digest without treating it as config`() {
        let running = ImageIdentities(
            config: "sha256:configcccc",
            manifests: ["sha256:platformbbbb"],
        )
        let catalog = ImageIdentities(manifests: ["sha256:platformbbbb"])
        #expect(!ApplicationImageFacts.updateAvailable(running: running, catalog: catalog))
        let miss = ImageIdentities(manifests: ["sha256:otherpin"])
        #expect(!ApplicationImageFacts.updateAvailable(running: running, catalog: miss))
    }

    @Test func `older image is update available`() {
        #expect(
            ApplicationImageFacts.updateAvailable(
                running: "sha256:aaa111",
                catalog: "lscr.io/app@sha256:bbb222",
            ),
        )
        #expect(
            !ApplicationImageFacts.updateAvailable(
                running: "sha256:aaa111",
                catalog: "sha256:AAA111",
            ),
        )
        #expect(!ApplicationImageFacts.updateAvailable(running: nil, catalog: "sha256:bbb"))
        #expect(!ApplicationImageFacts.updateAvailable(running: "sha256:aaa", catalog: nil))
    }
}

@Suite(.serialized)
final class ApplicationImageFactsCommandTests {
    @Test func `running inspects the image after the container`() async throws {
        let compose = IDComposeRunner()
        let docker = IdentityDockerRunner()
        docker.containerJSON = """
        [{"Id":"0123456789abcdef","Image":"sha256:configcccc",\
        "Config":{"Image":"lscr.io/linuxserver/qbittorrent:latest"},\
        "State":{"Running":true}}]
        """
        docker.imageJSON = """
        [{"Id":"sha256:configcccc","RepoTags":["lscr.io/linuxserver/qbittorrent:latest"],\
        "RepoDigests":["lscr.io/linuxserver/qbittorrent@sha256:platformbbbb"],\
        "Architecture":"arm64","Os":"linux"}]
        """
        docker.manifestJSON = """
        {"Descriptor":{"digest":"sha256:platformbbbb",\
        "mediaType":"application/vnd.oci.image.manifest.v1+json"},\
        "SchemaV2Manifest":{"config":{"digest":"sha256:configcccc"}}}
        """
        let facts = try await ComposeRuntime.$runnerOverride.withValue(compose) {
            try await DockerCLI.$runnerOverride.withValue(docker) {
                try ApplicationImageFacts.running(
                    id: "app-qb",
                    project: "barkvisor-appqb",
                    dataDir: FileManager.default.temporaryDirectory,
                )
            }
        }
        #expect(facts.count == 1)
        #expect(facts[0].image == "lscr.io/linuxserver/qbittorrent:latest")
        #expect(facts[0].digest == "sha256:platformbbbb")
        #expect(docker.inspectTargets.contains { $0.contains("cid1") })
        #expect(docker.inspectTargets.contains { $0.contains("sha256:configcccc") })
    }

    @Test func `unchanged image snapshot is not an update`() async throws {
        let compose = IDComposeRunner()
        let docker = IdentityDockerRunner()
        docker.containerJSON = """
        [{"Id":"0123456789abcdef","Image":"sha256:configcccc",\
        "Config":{"Image":"lscr.io/linuxserver/qbittorrent:latest"}}]
        """
        docker.imageJSON = """
        [{"Id":"sha256:configcccc","RepoTags":["lscr.io/linuxserver/qbittorrent:latest"],\
        "RepoDigests":["lscr.io/linuxserver/qbittorrent@sha256:platformbbbb"]}]
        """
        docker.manifestJSON = """
        [{"Descriptor":{"digest":"sha256:indexaaaa","mediaType":"application/vnd.oci.image.index.v1+json",\
        "platform":{"architecture":"unknown","os":"linux"}},\
        "SchemaV2Manifest":{"config":{"digest":"sha256:configcccc"}}},\
        {"Descriptor":{"digest":"sha256:platformbbbb","mediaType":"application/vnd.oci.image.manifest.v1+json",\
        "platform":{"architecture":"arm64","os":"linux"}},\
        "SchemaV2Manifest":{"config":{"digest":"sha256:configcccc"}}},\
        {"Descriptor":{"digest":"sha256:platformbbbb","mediaType":"application/vnd.oci.image.manifest.v1+json",\
        "platform":{"architecture":"amd64","os":"linux"}},\
        "SchemaV2Manifest":{"config":{"digest":"sha256:configcccc"}}}]
        """
        let snap = try await ComposeRuntime.$runnerOverride.withValue(compose) {
            try await DockerCLI.$runnerOverride.withValue(docker) {
                try ApplicationImageFacts.snapshot(
                    id: "app-qb",
                    project: "barkvisor-appqb",
                    image: "lscr.io/linuxserver/qbittorrent:latest",
                    dataDir: FileManager.default.temporaryDirectory,
                    os: "linux",
                    arch: "arm64",
                )
            }
        }
        #expect(snap.digest == snap.catalogDigest)
        #expect(snap.digest != nil)
        #expect(!ApplicationImageFacts.updateAvailable(running: snap.digest, catalog: snap.catalogDigest))
    }

    @Test func `new registry manifest snapshot is an update`() async throws {
        let compose = IDComposeRunner()
        let docker = IdentityDockerRunner()
        docker.containerJSON = """
        [{"Id":"0123456789abcdef","Image":"sha256:configold",\
        "Config":{"Image":"lscr.io/linuxserver/qbittorrent:latest"}}]
        """
        docker.imageJSON = """
        [{"Id":"sha256:configold","RepoTags":["lscr.io/linuxserver/qbittorrent:latest"],\
        "RepoDigests":["lscr.io/linuxserver/qbittorrent@sha256:platformold"]}]
        """
        docker.manifestJSON = """
        {"Descriptor":{"digest":"sha256:platformnew",\
        "mediaType":"application/vnd.oci.image.manifest.v1+json"},\
        "SchemaV2Manifest":{"config":{"digest":"sha256:confignew"}}}
        """
        let snap = try await ComposeRuntime.$runnerOverride.withValue(compose) {
            try await DockerCLI.$runnerOverride.withValue(docker) {
                try ApplicationImageFacts.snapshot(
                    id: "app-qb",
                    project: "barkvisor-appqb",
                    image: "lscr.io/linuxserver/qbittorrent:latest",
                    dataDir: FileManager.default.temporaryDirectory,
                )
            }
        }
        #expect(ApplicationImageFacts.updateAvailable(running: snap.digest, catalog: snap.catalogDigest))
        #expect(snap.digest != snap.catalogDigest)
    }

    @Test func `digest pinned reference is current when repo digest matches`() async throws {
        let compose = IDComposeRunner()
        let docker = IdentityDockerRunner()
        docker.containerJSON = """
        [{"Id":"0123456789abcdef","Image":"sha256:configcccc",\
        "Config":{"Image":"lscr.io/linuxserver/qbittorrent@sha256:platformbbbb"}}]
        """
        docker.imageJSON = """
        [{"Id":"sha256:configcccc",\
        "RepoTags":["lscr.io/linuxserver/qbittorrent:latest"],\
        "RepoDigests":["lscr.io/linuxserver/qbittorrent@sha256:platformbbbb"]}]
        """
        docker.manifestJSON = """
        {"Descriptor":{"digest":"sha256:platformbbbb",\
        "mediaType":"application/vnd.oci.image.manifest.v1+json"},\
        "SchemaV2Manifest":{"config":{"digest":"sha256:configcccc"}}}
        """
        let snap = try await ComposeRuntime.$runnerOverride.withValue(compose) {
            try await DockerCLI.$runnerOverride.withValue(docker) {
                try ApplicationImageFacts.snapshot(
                    id: "app-qb",
                    project: "barkvisor-appqb",
                    image: "lscr.io/linuxserver/qbittorrent@sha256:platformbbbb",
                    dataDir: FileManager.default.temporaryDirectory,
                )
            }
        }
        #expect(!ApplicationImageFacts.updateAvailable(running: snap.digest, catalog: snap.catalogDigest))
    }
}

private final class IDComposeRunner: ComposeCommandRunning, @unchecked Sendable {
    func run(
        arguments: [String],
        projectDirectory _: URL,
        timeout _: TimeInterval,
    ) throws -> CommandResult {
        if arguments.contains("-q") {
            return CommandResult(exitCode: 0, stdout: Data("cid1\n".utf8), stderr: Data())
        }
        throw BarkVisorError.internalError("unexpected compose")
    }
}

private final class IdentityDockerRunner: DockerCommandRunning, @unchecked Sendable {
    var containerJSON = "[]"
    var imageJSON = "[]"
    var manifestJSON = "{}"
    var inspectTargets: [[String]] = []

    func run(arguments: [String], timeout _: TimeInterval) throws -> CommandResult {
        if arguments.first == "inspect" {
            let targets = Array(arguments.dropFirst())
            inspectTargets.append(targets)
            let json = targets.contains(where: isImageInspectTarget) ? imageJSON : containerJSON
            return CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        }
        if arguments.contains("manifest") {
            return CommandResult(exitCode: 0, stdout: Data(manifestJSON.utf8), stderr: Data())
        }
        return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    private func isImageInspectTarget(_ target: String) -> Bool {
        let value = target.lowercased()
        return value.hasPrefix("sha256:") || value.contains("/") || value.contains("@")
    }
}

struct ComposeLogHintsTests {
    @Test func `qbittorrent temporary password is read from the log line`() {
        let line =
            "qbittorrent  | The WebUI administrator password was not set. A temporary password is provided for this session: s3cretPass"
        #expect(ComposeLogHints.firstPassword(inLine: line) == "s3cretPass")
        #expect(ComposeLogHints.isFirstPasswordLine(line))
        let text = """
        jellyfin | ready
        \(line)
        qbittorrent | This password will remain valid until the container is stopped.
        """
        #expect(ComposeLogHints.firstPassword(in: text) == "s3cretPass")
        let stamped =
            "2026-09-08T20:41:02.123456789Z qbittorrent  | A temporary password is provided for this session: helloQB"
        #expect(ComposeLogHints.firstPassword(inLine: stamped) == "helloQB")
        #expect(
            ComposeLogHints.firstPassword(
                inLine: "2026-09-08T20:41:02Z qbittorrent  | The WebUI administrator password was not set.",
            ) == nil,
        )
    }

    @Test func `unrelated logs have no first password`() {
        #expect(ComposeLogHints.firstPassword(in: "jellyfin | listening on 8096") == nil)
        #expect(!ComposeLogHints.isFirstPasswordLine("warn: password auth failed"))
    }
}

struct ComposeVolumeRootsTests {
    @Test func `canonical root is dataDir workloads id`() {
        let dataDir = URL(fileURLWithPath: "/var/lib/barkvisor")
        let paths = ComposeRuntime.volumeRoots(id: "app-1", named: ["config", "data"], dataDir: dataDir)
        #expect(paths.first == "/var/lib/barkvisor/workloads/app-1")
        #expect(paths.contains("/var/lib/barkvisor/workloads/app-1/volumes"))
        #expect(paths.contains("/var/lib/barkvisor/workloads/app-1/volumes/config"))
        #expect(paths.contains("/var/lib/barkvisor/workloads/app-1/volumes/data"))
    }
}
