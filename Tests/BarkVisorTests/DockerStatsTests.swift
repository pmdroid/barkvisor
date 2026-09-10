import Foundation
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
struct DockerStatsTests {
    @Test func `byte sizes cover docker units`() {
        #expect(DockerStats.parseBytes("0B") == 0)
        #expect(DockerStats.parseBytes("42B") == 42)
        #expect(DockerStats.parseBytes("1.5kB") == 1_500)
        #expect(DockerStats.parseBytes("2KB") == 2_000)
        #expect(DockerStats.parseBytes("3.25MB") == 3_250_000)
        #expect(DockerStats.parseBytes("1.2GB") == 1_200_000_000)
        #expect(DockerStats.parseBytes("11.22MiB") == 11_765_023)
        #expect(DockerStats.parseBytes("2GiB") == 2_147_483_648)
        #expect(DockerStats.parseBytes("512KiB") == 524_288)
        #expect(DockerStats.parseBytes("--") == 0)
        #expect(DockerStats.parseBytes("") == 0)
        #expect(DockerStats.parseBytes("bogus") == 0)
    }

    @Test func `cpu percent tolerates docker formatting`() {
        #expect(DockerStats.parsePercent("12.34%") == 12.34)
        #expect(DockerStats.parsePercent("0.00%") == 0)
        #expect(DockerStats.parsePercent(nil) == 0)
        #expect(DockerStats.parsePercent("--") == 0)
        #expect(DockerStats.parsePercent("") == 0)
    }

    @Test func `single stats line maps to a sample`() {
        let line = """
        {"BlockIO":"0B / 0B","CPUPerc":"0.42%","ID":"abc123","MemPerc":"0.58%",\
        "MemUsage":"11.22MiB / 2GiB","Name":"barkvisor-app-web-1","NetIO":"1.5kB / 2.3kB"}
        """
        let sample = DockerStats.parseLine(line)
        #expect(sample?.name == "barkvisor-app-web-1")
        #expect(sample?.cpuPercent == 0.42)
        #expect(sample?.memoryUsedBytes == 11_765_023)
        #expect(sample?.memoryLimitBytes == 2_147_483_648)
        #expect(sample?.networkRxBytes == 1_500)
        #expect(sample?.networkTxBytes == 2_300)
    }

    @Test func `stats lines without a name are skipped`() {
        #expect(DockerStats.parseLine("") == nil)
        #expect(DockerStats.parseLine("not json") == nil)
        #expect(DockerStats.parseLine("{}") == nil)
    }

    @Test func `project output aggregates every container`() {
        let output = """
        {"CPUPerc":"0.42%","MemUsage":"11.22MiB / 2GiB","Name":"proj-web-1","NetIO":"1.5kB / 2.3kB"}
        {"CPUPerc":"1.10%","MemUsage":"44MiB / 2GiB","Name":"proj-db-1","NetIO":"500B / 700B"}
        """
        let totals = DockerStats.totals(DockerStats.parse(output: output))
        #expect(totals.containerCount == 2)
        #expect(abs(totals.cpuPercent - 1.52) < 0.001)
        #expect(totals.memoryUsedBytes == 11_765_023 + 46_137_344)
        #expect(totals.memoryLimitBytes == 2 * 2_147_483_648)
        #expect(totals.networkRxBytes == 2_000)
        #expect(totals.networkTxBytes == 3_000)
    }

    @Test func `snapshot sums the compose project containers`() throws {
        ComposeTestIsolation.lock.lock()
        defer {
            ComposeTestIsolation.installFailFast()
            ComposeTestIsolation.lock.unlock()
        }
        ComposeRuntime.runner = StatsComposeRunner(ids: ["aaa", "bbb"])
        DockerCLI.runner = StatsDockerRunner(output: """
        {"CPUPerc":"2.50%","MemUsage":"128MiB / 4GiB","Name":"c1","NetIO":"10kB / 20kB"}
        {"CPUPerc":"0.50%","MemUsage":"128MiB / 4GiB","Name":"c2","NetIO":"5kB / 6kB"}
        """)

        let totals = try #require(DockerStats.snapshot(id: "app-1", project: "barkvisor-app1"))
        #expect(totals.containerCount == 2)
        #expect(totals.cpuPercent == 3.0)
        #expect(totals.memoryUsedBytes == 2 * 134_217_728)
        #expect(totals.memoryLimitBytes == 2 * 4_294_967_296)
        #expect(totals.networkRxBytes == 15_000)
        #expect(totals.networkTxBytes == 26_000)
    }

    @Test func `snapshot is nil without running containers`() {
        ComposeTestIsolation.lock.lock()
        defer {
            ComposeTestIsolation.installFailFast()
            ComposeTestIsolation.lock.unlock()
        }
        ComposeRuntime.runner = StatsComposeRunner(ids: [])
        #expect(DockerStats.snapshot(id: "app-1", project: "barkvisor-app1") == nil)
    }

    @Test func `metric samples decode payloads without network fields`() throws {
        let legacy = """
        {"timestamp":"2026-09-10T00:00:00Z","cpuPercent":1.5,"memoryUsedMB":128,\
        "diskReadBytes":10,"diskWriteBytes":20}
        """.data(using: .utf8)!
        let sample = try JSONDecoder().decode(MetricSample.self, from: legacy)
        #expect(sample.networkRxBytes == 0)
        #expect(sample.networkTxBytes == 0)
        #expect(sample.memoryLimitMB == 0)
        let encoded = try JSONEncoder().encode(sample)
        let roundTrip = try JSONDecoder().decode(MetricSample.self, from: encoded)
        #expect(roundTrip.networkRxBytes == 0)
        #expect(roundTrip.memoryLimitMB == 0)
    }

    @Test func `aggregation keeps vm and app usage apart`() {
        func sample(cpu: Double, mem: Int, rx: Int64 = 0, tx: Int64 = 0) -> MetricSample {
            MetricSample(
                timestamp: "2026-09-10T00:00:00Z",
                cpuPercent: cpu,
                memoryUsedMB: mem,
                diskReadBytes: 0,
                diskWriteBytes: 0,
                networkRxBytes: rx,
                networkTxBytes: tx,
            )
        }
        let split = MetricsAggregation.split(
            samples: [
                "vm-1": sample(cpu: 10, mem: 512),
                "app-1": sample(cpu: 2.5, mem: 128, rx: 1_000, tx: 2_000),
                "app-2": sample(cpu: 1.5, mem: 64, rx: 500, tx: 600),
            ],
            appIDs: ["app-1", "app-2"],
        )
        #expect(split.vmCpuPercent == 10)
        #expect(split.vmMemoryMB == 512)
        #expect(split.appCpuPercent == 4.0)
        #expect(split.appMemoryMB == 192)
        #expect(split.appNetworkRxBytes == 1_500)
        #expect(split.appNetworkTxBytes == 2_600)
    }

    @Test func `startApp records collection until stopApp`() async {
        ComposeTestIsolation.installFailFast()
        let collector = MetricsCollector()
        await collector.startApp(id: "app-1", project: "barkvisor-app1")
        #expect(await collector.isCollectingApp("app-1"))
        await collector.stopApp("app-1")
        #expect(await collector.isCollectingApp("app-1") == false)
        #expect(await collector.latestSamples()["app-1"] == nil)
    }

    @Test func `stop does not cancel an unrelated app collector`() async {
        ComposeTestIsolation.installFailFast()
        let collector = MetricsCollector()
        await collector.startApp(id: "app-keep", project: "barkvisor-appkeep")
        await collector.stop(vmID: "vm-other")
        #expect(await collector.isCollectingApp("app-keep"))
        await collector.stopApp("app-keep")
        #expect(await collector.isCollectingApp("app-keep") == false)
    }
}

struct StatsComposeRunner: ComposeCommandRunning {
    var ids: [String]

    func run(
        arguments _: [String],
        projectDirectory _: URL,
        timeout _: TimeInterval,
    ) throws -> CommandResult {
        CommandResult(
            exitCode: 0,
            stdout: Data((ids.joined(separator: "\n") + (ids.isEmpty ? "" : "\n")).utf8),
            stderr: Data(),
        )
    }
}

struct StatsDockerRunner: DockerCommandRunning {
    var output: String

    func run(arguments _: [String], timeout _: TimeInterval) throws -> CommandResult {
        CommandResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
    }
}
