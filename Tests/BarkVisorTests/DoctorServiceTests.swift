import Foundation
import Testing
@testable import BarkVisorCore

struct DoctorServiceTests {
    private func linuxReady() -> HostBridgeReadiness {
        HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            helperPath: "/usr/lib/qemu/qemu-bridge-helper",
            helperSetuid: true,
            aclAllowsSuggested: true,
            bridges: [HostBridgeSnapshot(name: "br0", enslaved: ["eth0"])],
            defaultRouteInterface: "br0",
        )).readiness
    }

    private func linuxMissing() -> HostBridgeReadiness {
        HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            helperPath: "/usr/lib/qemu/qemu-bridge-helper",
            helperSetuid: false,
            aclAllowsSuggested: false,
            bridges: [],
            defaultRouteInterface: "eth0",
        )).readiness
    }

    private func macReady() -> HostBridgeReadiness {
        HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            bridges: [HostBridgeSnapshot(name: "en0", enslaved: [])],
            macSocketVmnet: true,
        )).readiness
    }

    private func macMissing() -> HostBridgeReadiness {
        HostBridgeFactsService.assemble(from: HostBridgeFactInputs(macSocketVmnet: true)).readiness
    }

    private func inputs(
        os: String = "Linux",
        uid: UInt32 = 501,
        qemuPath: String? = "/usr/bin/qemu-system-aarch64",
        qemuProcesses: [DoctorProcess] = [],
        kvmPresent: Bool = true,
        kvmAccessible: Bool = true,
        swtpmPath: String? = "/usr/bin/swtpm",
        swtpmRequired: Bool = true,
        healthOK: Bool = true,
        healthDetail: String = "HTTP 200",
        hostBridge: HostBridgeReadiness? = nil,
        suggestedBridgeAddress: String? = "192.168.1.2",
        macSocketServiceRunning: Bool = false,
    ) -> DoctorFactInputs {
        DoctorFactInputs(
            os: os,
            uid: uid,
            qemuPath: qemuPath,
            qemuProcesses: qemuProcesses,
            kvmPresent: kvmPresent,
            kvmAccessible: kvmAccessible,
            swtpmPath: swtpmPath,
            swtpmRequired: swtpmRequired,
            healthURL: "http://127.0.0.1:7777/api/health",
            healthOK: healthOK,
            healthDetail: healthDetail,
            hostBridge: hostBridge ?? linuxReady(),
            suggestedBridgeAddress: suggestedBridgeAddress,
            macSocketServiceRunning: macSocketServiceRunning,
        )
    }

    private func check(_ report: DoctorReport, _ id: String) -> DoctorCheck {
        report.checks.first { $0.id == id } ?? DoctorCheck(id: id, status: .fail, detail: "missing")
    }

    @Test func `unprivileged daemon uid is warn not fail`() {
        let report = DoctorService.assemble(from: inputs(uid: 501))
        #expect(check(report, "daemon-uid").status == .warn)
        #expect(check(report, "daemon-uid").detail.contains("501"))
        #expect(!report.privileged)
        #expect(report.ok)
    }

    @Test func `root daemon uid is ok and privileged`() {
        let report = DoctorService.assemble(from: inputs(uid: 0))
        #expect(check(report, "daemon-uid").status == .ok)
        #expect(report.privileged)
        #expect(report.ok)
    }

    @Test func `missing qemu fails`() {
        let report = DoctorService.assemble(from: inputs(qemuPath: nil))
        #expect(check(report, "qemu").status == .fail)
        #expect(!report.ok)
        #expect(check(report, "qemu").detail.contains(DoctorService.qemuBinaryName()))
    }

    @Test func `qemu binary name follows host guest arch`() {
        let name = DoctorService.qemuBinaryName()
        #expect(name == "qemu-system-\(PlatformCapabilities.defaultGuestArch)")
        #expect(name.hasPrefix("qemu-system-"))
    }

    @Test func `no qemu process is skip`() {
        let report = DoctorService.assemble(from: inputs(qemuProcesses: []))
        #expect(check(report, "qemu-process").status == .skip)
    }

    @Test func `root qemu process is warn`() {
        let report = DoctorService.assemble(from: inputs(
            qemuProcesses: [DoctorProcess(pid: 42, uid: 0, command: "qemu-system-aarch64")],
        ))
        #expect(check(report, "qemu-process").status == .warn)
        #expect(check(report, "qemu-process").detail.contains("uid=0"))
        #expect(report.ok)
    }

    @Test func `dropped qemu process is ok`() {
        let report = DoctorService.assemble(from: inputs(
            qemuProcesses: [DoctorProcess(pid: 9, uid: 107, command: "qemu-system-aarch64")],
        ))
        #expect(check(report, "qemu-process").status == .ok)
        #expect(check(report, "qemu-process").detail.contains("107"))
    }

    @Test func `macos qemu skip mentions hvf cannot drop`() {
        let report = DoctorService.assemble(from: inputs(os: "macOS", hostBridge: macReady()))
        #expect(check(report, "qemu-process").status == .skip)
        #expect(check(report, "qemu-process").detail.contains("HVF"))
    }

    @Test func `kvm skipped on macos`() {
        let report = DoctorService.assemble(from: inputs(
            os: "macOS",
            kvmPresent: false,
            hostBridge: macReady(),
        ))
        #expect(check(report, "kvm").status == .skip)
    }

    @Test func `missing kvm fails on linux`() {
        let report = DoctorService.assemble(from: inputs(kvmPresent: false))
        #expect(check(report, "kvm").status == .fail)
        #expect(!report.ok)
    }

    @Test func `unreadable kvm warns on linux`() {
        let report = DoctorService.assemble(from: inputs(kvmPresent: true, kvmAccessible: false))
        #expect(check(report, "kvm").status == .warn)
        #expect(report.ok)
    }

    @Test func `swtpm required missing fails`() {
        let report = DoctorService.assemble(from: inputs(swtpmPath: nil, swtpmRequired: true))
        #expect(check(report, "swtpm").status == .fail)
        #expect(!report.ok)
    }

    @Test func `swtpm not required missing is skip`() {
        let report = DoctorService.assemble(from: inputs(swtpmPath: nil, swtpmRequired: false))
        #expect(check(report, "swtpm").status == .skip)
        #expect(report.ok)
    }

    @Test func `health failure fails the report`() {
        let report = DoctorService.assemble(from: inputs(
            healthOK: false,
            healthDetail: "connection refused",
        ))
        #expect(check(report, "api-health").status == .fail)
        #expect(check(report, "api-health").detail.contains("127.0.0.1:7777"))
        #expect(!report.ok)
    }

    @Test func `linux bridge reuses host facts and fails when privileged`() {
        let facts = linuxMissing()
        let report = DoctorService.assemble(from: inputs(
            uid: 0,
            hostBridge: facts,
            suggestedBridgeAddress: nil,
        ))
        #expect(report.hostBridge == facts)
        #expect(check(report, "linux-bridge").status == .fail)
        #expect(!report.ok)
    }

    @Test func `linux bridge missing is warn when unprivileged`() {
        let report = DoctorService.assemble(from: inputs(
            uid: 501,
            hostBridge: linuxMissing(),
            suggestedBridgeAddress: nil,
        ))
        #expect(check(report, "linux-bridge").status == .warn)
        #expect(report.ok)
    }

    @Test func `linux bridge ready without address warns`() {
        let report = DoctorService.assemble(from: inputs(
            hostBridge: linuxReady(),
            suggestedBridgeAddress: nil,
        ))
        #expect(check(report, "linux-bridge").status == .warn)
        #expect(check(report, "linux-bridge").detail.contains("br0"))
    }

    @Test func `macos socket missing fails when privileged`() {
        let report = DoctorService.assemble(from: inputs(
            os: "macOS",
            uid: 0,
            hostBridge: macMissing(),
        ))
        #expect(check(report, "macos-socket-vmnet").status == .fail)
        #expect(check(report, "linux-bridge").status == .skip)
        #expect(!report.ok)
    }

    @Test func `macos socket ready is ok`() {
        let report = DoctorService.assemble(from: inputs(
            os: "macOS",
            hostBridge: macReady(),
            macSocketServiceRunning: true,
        ))
        #expect(check(report, "macos-socket-vmnet").status == .ok)
        #expect(report.hostBridge.ready)
    }

    @Test func `linux skips socket_vmnet check`() {
        let report = DoctorService.assemble(from: inputs(os: "Linux"))
        #expect(check(report, "macos-socket-vmnet").status == .skip)
    }

    @Test func `json round trip keeps host bridge facts`() throws {
        let report = DoctorService.assemble(from: inputs())
        let data = try DoctorService.jsonData(report)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.hostBridge.suggestedBridge == HostBridgeFactsService.suggestedBridgeName)
    }

    @Test func `text and json omit cluster node quorum`() throws {
        let report = DoctorService.assemble(from: inputs(os: "macOS", hostBridge: macReady()))
        let text = DoctorService.renderText(report).lowercased()
        let json = try String(data: DoctorService.jsonData(report), encoding: .utf8) ?? ""
        for blob in [text, json.lowercased()] {
            #expect(!blob.contains("cluster"))
            #expect(!blob.contains("quorum"))
            #expect(!blob.contains(" node"))
            #expect(!blob.contains("nodes"))
        }
        #expect(text.contains("device") || json.lowercased().contains("device") || text.contains("workload"))
    }

    @Test func `health url uses configured port`() {
        let url = DoctorService.healthURL(port: 7_777)
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 7_777)
        #expect(url.path == "/api/health")
    }

    @Test func `ps parser reads pid uid command`() {
        let rows = DoctorProcessList.parse("  42  0 qemu-system-aarch64 -name demo\n  9 107 socket_vmnet\n")
        #expect(rows.count == 2)
        #expect(rows[0].pid == 42)
        #expect(rows[0].uid == 0)
        #expect(rows[1].uid == 107)
    }

    @Test func `cli is registered and stays read only`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/BarkVisorApp/main.swift"),
            encoding: .utf8,
        )
        #expect(app.contains("Doctor.self"))
        #expect(app.contains("struct Doctor"))
        #expect(app.contains("DoctorService.probe"))
        #expect(app.contains("Never mutates"))
        #expect(!app.contains("HelperXPCClient"))
        #expect(!app.contains("SMJobBless"))

        let doctor = try String(
            contentsOf: root.appendingPathComponent("Sources/BarkVisorCore/Services/DoctorService.swift"),
            encoding: .utf8,
        )
        #expect(doctor.contains("HostBridgeFactsService.probe"))
        #expect(doctor.contains("never applies") || doctor.contains("Never applies") || doctor.contains("never starts"))
        #expect(!doctor.contains("HelperXPCClient"))
        #expect(!doctor.contains("SMJobBless"))
        #expect(!doctor.localizedCaseInsensitiveContains("cluster"))
        #expect(!doctor.localizedCaseInsensitiveContains("quorum"))
    }

    @Test func `swtpm required follows windows guest profiles`() {
        let required = DoctorService.swtpmRequired()
        let expected = GuestProfiles.profilesCompatible(withHostArch: PlatformCapabilities.hostArch)
            .contains { $0.defaultTPMEnabled }
        #expect(required == expected)
    }
}
