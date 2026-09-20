import Foundation
import Testing
@testable import BarkVisorCore

struct DockerEngineTests {
    @Test func `import includes contexts and repairs an existing config without overwriting it`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let context = source.appendingPathComponent("contexts/meta/orbstack/meta.json")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: context.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(#"{"currentContext":"orbstack"}"#.utf8).write(to: source.appendingPathComponent("config.json"))
        try Data(#"{"Name":"orbstack"}"#.utf8).write(to: context)
        let candidates = [source.appendingPathComponent("config.json").path]
        DockerEngine.importDockerConfig(into: destination, candidates: candidates)
        #expect(try Data(contentsOf: destination.appendingPathComponent("config.json")) ==
            Data(contentsOf: source.appendingPathComponent("config.json")))
        #expect(try Data(contentsOf: destination.appendingPathComponent("contexts/meta/orbstack/meta.json")) == Data(contentsOf: context))
        try Data("existing".utf8).write(to: destination.appendingPathComponent("config.json"))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("contexts"))
        DockerEngine.importDockerConfig(into: destination, candidates: candidates)
        #expect(try String(contentsOf: destination.appendingPathComponent("config.json"), encoding: .utf8) == "existing")
        #expect(try Data(contentsOf: destination.appendingPathComponent("contexts/meta/orbstack/meta.json")) == Data(contentsOf: context))
    }

    @Test func `macos candidates include OrbStack and Docker Desktop`() {
        let paths = DockerEngine.candidatePaths(os: "macOS")
        #expect(paths.contains("/usr/local/bin/docker"))
        #expect(paths.contains("/opt/homebrew/bin/docker"))
        #expect(paths.contains("/Applications/OrbStack.app/Contents/MacOS/xbin/docker"))
        #expect(paths.contains("/Applications/Docker.app/Contents/Resources/bin/docker"))
    }

    @Test func `linux candidates prefer usr bin docker`() {
        let paths = DockerEngine.candidatePaths(os: "Linux")
        #expect(paths.first == "/usr/bin/docker")
        #expect(paths.contains("/usr/local/bin/docker"))
    }

    @Test func `launchd PATH still finds OrbStack docker`() {
        let found = DockerEngine.resolveDockerPath(
            os: "macOS",
            pathEnvironment: "/usr/bin:/bin:/usr/sbin:/sbin",
            whichPath: nil,
            isExecutable: { $0 == "/usr/local/bin/docker" },
        )
        #expect(found == "/usr/local/bin/docker")
    }

    @Test func `whichPath wins over extra candidates`() {
        let found = DockerEngine.resolveDockerPath(
            os: "macOS",
            pathEnvironment: "/usr/bin",
            whichPath: "/opt/homebrew/bin/docker",
            isExecutable: { path in
                path == "/opt/homebrew/bin/docker" || path == "/usr/local/bin/docker"
            },
        )
        #expect(found == "/opt/homebrew/bin/docker")
    }

    @Test func `empty PATH with no candidates is nil`() {
        let found = DockerEngine.resolveDockerPath(
            os: "macOS",
            pathEnvironment: "/usr/bin:/bin",
            whichPath: nil,
            isExecutable: { _ in false },
        )
        #expect(found == nil)
    }

    @Test func `PATH hit is used before extra candidates`() {
        let found = DockerEngine.resolveDockerPath(
            os: "macOS",
            pathEnvironment: "/opt/custom/bin:/usr/bin",
            whichPath: nil,
            isExecutable: { path in
                path == "/opt/custom/bin/docker" || path == "/usr/local/bin/docker"
            },
        )
        #expect(found == "/opt/custom/bin/docker")
    }

    @Test func `compose sibling of docker is found without user plugin dir`() {
        let found = DockerEngine.resolveComposePath(
            dockerPath: "/usr/local/bin/docker",
            os: "macOS",
            isExecutable: { $0 == "/usr/local/bin/docker-compose" },
        )
        #expect(found == "/usr/local/bin/docker-compose")
    }

    @Test func `compose invocation uses standalone when plugin is missing`() throws {
        let snap = DockerEngineSnapshot(
            os: "macOS",
            dockerPath: "/usr/local/bin/docker",
            composeOK: true,
            composePlugin: false,
            composePath: "/usr/local/bin/docker-compose",
        )
        let invoke = try DockerEngine.composeInvocation(snapshot: snap)
        #expect(invoke.executable.path == "/usr/local/bin/docker-compose")
        #expect(invoke.prefix.isEmpty)
    }

    @Test func `cli config links compose plugin next to docker`() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-docker-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let compose = bin.appendingPathComponent("docker-compose")
        FileManager.default.createFile(atPath: compose.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compose.path)
        let docker = bin.appendingPathComponent("docker")
        FileManager.default.createFile(atPath: docker.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
        let dataDir = tmp.appendingPathComponent("data", isDirectory: true)
        let cfg = DockerEngine.prepareCLIConfig(dataDir: dataDir, dockerPath: docker.path)
        let link = cfg.appendingPathComponent("cli-plugins").appendingPathComponent("docker-compose")
        #expect(FileManager.default.fileExists(atPath: link.path))
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(dest == compose.path)
    }

    @Test func `docker config candidates include launchd user socket owner`() {
        let paths = DockerEngine.dockerConfigJSONCandidates(
            home: "/var/root",
            dockerConfigEnv: nil,
            socketOwner: "pascal",
        )
        #expect(paths.contains("/var/root/.docker/config.json"))
        #expect(paths.contains("/Users/pascal/.docker/config.json"))
    }

    @Test func `compose invocation uses docker compose plugin when present`() throws {
        let snap = DockerEngineSnapshot(
            os: "macOS",
            dockerPath: "/usr/local/bin/docker",
            composeOK: true,
            composePlugin: true,
        )
        let invoke = try DockerEngine.composeInvocation(snapshot: snap)
        #expect(invoke.executable.path == "/usr/local/bin/docker")
        #expect(invoke.prefix == ["compose"])
    }
}
