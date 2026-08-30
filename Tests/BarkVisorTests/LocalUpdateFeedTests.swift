import Foundation
import Testing
@testable import BarkVisorCore

/// Local GitHub-shaped update feed (`scripts/serve-local-updates.sh`) for Apply tests.
struct LocalUpdateFeedTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var script: URL {
        repoRoot.appendingPathComponent("scripts/serve-local-updates.sh")
    }

    private func run(args: [String]) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path] + args
        proc.currentDirectoryURL = repoRoot
        proc.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func extractFeedJSON(from output: String) throws -> Data {
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start < end
        else {
            throw NSError(
                domain: "LocalUpdateFeedTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no JSON array in:\n\(output)"],
            )
        }
        return Data(String(output[start ... end]).utf8)
    }

    private func makeAssetDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-update-feed-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test func `script exists and is executable`() {
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
    }

    @Test func `dry-run feed is pickable as a newer release`() throws {
        let tmp = try makeAssetDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let deb = tmp.appendingPathComponent("barkvisor_9.9.9_amd64.deb")
        try Data("fake-deb".utf8).write(to: deb)
        try Data(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  barkvisor_9.9.9_amd64.deb\n"
                .utf8,
        ).write(to: tmp.appendingPathComponent("barkvisor_9.9.9_amd64.deb.sha256"))

        let out = try run(args: ["--dry-run", "--dir", tmp.path])
        #expect(out.0 == 0, "dry-run exit \(out.0): \(out.1)")
        #expect(out.1.contains("BARKVISOR_UPDATE_URL=http://127.0.0.1:8765/repos/pmdroid/barkvisor/releases"))
        #expect(out.1.contains("Test update URL"))

        let json = try extractFeedJSON(from: out.1)
        let releases = try UpdateReleaseParser.decodeReleases(json)
        let info = try UpdateReleaseParser.pick(
            releases: releases,
            channel: .stable,
            currentVersion: "1.0.0",
            kind: .deb,
            hostArch: "x86_64",
        )
        #expect(info?.version == "9.9.9")
        #expect(info?.packageKind == .deb)
        #expect(info?.packageURL.contains("127.0.0.1") == true)
        #expect(info?.checksumURL.contains("127.0.0.1") == true)
        #expect(info?.packageURL.contains("/download/") == true)
        #expect(info?.checksumURL.hasSuffix(".deb.sha256") == true)
    }

    @Test func `dry-run download urls are loopback`() throws {
        let tmp = try makeAssetDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data("pkg".utf8).write(to: tmp.appendingPathComponent("BarkVisor-2.0.0.pkg"))
        try Data(
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  BarkVisor-2.0.0.pkg\n".utf8,
        ).write(to: tmp.appendingPathComponent("BarkVisor-2.0.0.pkg.sha256"))

        let out = try run(args: ["--dry-run", "--dir", tmp.path, "--port", "9001", "--tag", "v2.0.0"])
        #expect(out.0 == 0, "dry-run exit \(out.0): \(out.1)")
        #expect(out.1.contains("BARKVISOR_UPDATE_URL=http://127.0.0.1:9001/repos/pmdroid/barkvisor/releases"))

        let json = try extractFeedJSON(from: out.1)
        let releases = try UpdateReleaseParser.decodeReleases(json)
        #expect(releases.count == 1)
        for asset in releases[0].assets {
            #expect(asset.url.hasPrefix("http://127.0.0.1:9001/download/"))
            #expect(!asset.url.contains("0.0.0.0"))
            #expect(!asset.url.contains("api.github.com"))
        }
        let info = try UpdateReleaseParser.pick(
            releases: releases,
            channel: .stable,
            currentVersion: "1.0.0",
            kind: .pkg,
            hostArch: "arm64",
        )
        #expect(info?.version == "2.0.0")
        #expect(info?.packageURL.contains("127.0.0.1:9001") == true)
    }

    @Test func `tag override is the advertised version`() throws {
        let tmp = try makeAssetDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data("old-name".utf8).write(to: tmp.appendingPathComponent("barkvisor_0.0.0-dev_arm64.deb"))
        try Data(
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  barkvisor_0.0.0-dev_arm64.deb\n"
                .utf8,
        ).write(to: tmp.appendingPathComponent("barkvisor_0.0.0-dev_arm64.deb.sha256"))

        let out = try run(args: ["--dry-run", "--dir", tmp.path, "--tag", "v9.9.9"])
        #expect(out.0 == 0, "dry-run exit \(out.0): \(out.1)")
        let json = try extractFeedJSON(from: out.1)
        let releases = try UpdateReleaseParser.decodeReleases(json)
        let info = try UpdateReleaseParser.pick(
            releases: releases,
            channel: .stable,
            currentVersion: "1.0.0",
            kind: .deb,
            hostArch: "arm64",
        )
        #expect(info?.version == "9.9.9")
    }

    @Test func `refuses missing dir`() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-update-missing-\(UUID().uuidString)")
        let out = try run(args: ["--dry-run", "--dir", missing.path])
        #expect(out.0 != 0)
        #expect(out.1.contains("directory not found"))
    }

    @Test func `refuses empty dir`() throws {
        let tmp = try makeAssetDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let out = try run(args: ["--dry-run", "--dir", tmp.path])
        #expect(out.0 != 0)
        #expect(out.1.contains("no barkvisor_*.deb or *.pkg"))
    }

    @Test func `default UpdateService URL stays on GitHub Releases`() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/BarkVisorCore/Services/UpdateService.swift",
            ),
            encoding: .utf8,
        )
        #expect(source.contains("https://api.github.com/repos/pmdroid/barkvisor/releases"))
        #expect(source.contains("BARKVISOR_UPDATE_URL"))
    }
}
