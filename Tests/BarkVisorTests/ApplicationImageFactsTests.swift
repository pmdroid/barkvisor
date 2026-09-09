import Foundation
import Testing
@testable import BarkVisorCore

struct ApplicationImageFactsTests {
    @Test func `inspect json yields image and repo digest`() {
        let json = """
        [{"Config":{"Image":"lscr.io/linuxserver/qbittorrent:latest"},\
        "RepoDigests":["lscr.io/linuxserver/qbittorrent@sha256:aaa111bbb222"],\
        "Image":"sha256:deadbeef"}]
        """
        let facts = ApplicationImageFacts.parseInspect(json)
        #expect(facts.count == 1)
        #expect(facts[0].image == "lscr.io/linuxserver/qbittorrent:latest")
        #expect(facts[0].digest == "sha256:aaa111bbb222")
    }

    @Test func `registry verbose manifest yields descriptor digest`() {
        let json = """
        {"Descriptor":{"digest":"sha256:BBB222CCC333","mediaType":"application/vnd.oci.image.index.v1+json"}}
        """
        #expect(ApplicationImageFacts.parseRegistryDigest(json) == "sha256:bbb222ccc333")
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
