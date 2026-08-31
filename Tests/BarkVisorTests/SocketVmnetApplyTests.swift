import Foundation
import Testing
@testable import BarkVisorCore

struct SocketVmnetApplyTests {
    private func facts(ready: Bool = false) -> HostBridgeFacts {
        HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            bridges: ready ? [HostBridgeSnapshot(name: "en0", enslaved: [])] : [],
            defaultRouteInterface: "en0",
            macSocketVmnet: true,
        ))
    }

    private func probe(
        binary: String? = "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet",
        writable: Bool = true,
        brewPlist: String? = nil,
        brewPath: String? = "/opt/homebrew/bin/brew",
        sockets: [String] = [],
        ownedLoaded: Bool = false,
        brewLoaded: Bool = false,
        ownedPlistExists: Bool = false,
    ) -> SocketVmnetApplyProbe {
        SocketVmnetApplyProbe(
            facts: facts(ready: !sockets.isEmpty),
            interface: "en0",
            binaryPath: binary,
            ownedPlistPath: "/Library/LaunchDaemons/dev.barkvisor.socket-vmnet.en0.plist",
            ownedPlistExists: ownedPlistExists,
            ownedServiceLoaded: ownedLoaded,
            brewPath: brewPath,
            brewPlistPath: brewPlist,
            brewFormulaInstalled: binary != nil || brewPlist != nil,
            brewServiceLoaded: brewLoaded,
            sockets: sockets,
            canWriteLaunchDaemons: writable,
        )
    }

    @Test func `check reports socket plus service without writing`() {
        let result = SocketVmnetApply.evaluate(
            request: SocketVmnetApplyRequest(action: .check, interface: "en0"),
            probe: probe(
                sockets: ["/opt/homebrew/var/run/socket_vmnet"],
                brewLoaded: true,
            ),
        )
        #expect(result.success)
        #expect(!result.applied)
        #expect(result.changes.contains { $0.contains("socket=") && $0.contains("present=") })
        #expect(result.changes.contains { $0.contains("service=dev.barkvisor.socket-vmnet.en0") })
        #expect(result.changes.contains { $0.contains("service=homebrew.mxcl.socket_vmnet loaded=yes") })
        #expect(result.message.contains("socket present"))
        #expect(result.message.contains("service running"))
        #expect(!result.commands.joined().contains("brew install"))
        #expect(!result.commands.joined().contains("sudo brew"))
        #expect(!result.message.contains("HelperXPC"))
        #expect(!result.message.contains("SMJobBless"))
    }

    @Test func `setup prefers owned launchd when binary is writable`() {
        let result = SocketVmnetApply.evaluate(
            request: SocketVmnetApplyRequest(action: .setup, interface: "en0"),
            probe: probe(),
        )
        #expect(result.success)
        #expect(result.backend == SocketVmnetBackend.ownedLaunchd.rawValue)
        #expect(result.changes.contains { $0.contains("launchctl bootstrap") })
        #expect(!result.commands.joined().contains("sudo brew install"))
        #expect(!result.commands.joined().contains("brew install"))
    }

    @Test func `setup falls back to brew services of an already-installed formula`() {
        let result = SocketVmnetApply.evaluate(
            request: SocketVmnetApplyRequest(action: .start),
            probe: probe(
                binary: nil,
                writable: false,
                brewPlist: "/opt/homebrew/opt/socket_vmnet/homebrew.mxcl.socket_vmnet.plist",
            ),
        )
        #expect(result.success)
        #expect(result.backend == SocketVmnetBackend.homebrewService.rawValue)
        #expect(result.changes.contains { $0.contains("already-installed") })
        #expect(!result.changes.joined().contains("brew install socket_vmnet"))
        #expect(!result.commands.contains { $0.contains("sudo brew") })
    }

    @Test func `setup refuses when the formula is missing`() {
        let result = SocketVmnetApply.evaluate(
            request: SocketVmnetApplyRequest(action: .setup),
            probe: probe(binary: nil, writable: false, brewPlist: nil, brewPath: nil),
        )
        #expect(!result.success)
        #expect(result.refused)
        #expect(result.message.contains("brew install socket_vmnet"))
        #expect(result.message.contains("do not sudo brew install"))
        #expect(!result.commands.contains { $0.hasPrefix("sudo ") })
        #expect(!result.message.contains("HelperXPCClient"))
    }

    @Test func `stop plans bootout of owned and brew labels`() {
        let result = SocketVmnetApply.evaluate(
            request: SocketVmnetApplyRequest(action: .stop, interface: "en0"),
            probe: probe(ownedLoaded: true, brewLoaded: true, ownedPlistExists: true),
        )
        #expect(result.success)
        #expect(result.changes.contains { $0.contains("dev.barkvisor.socket-vmnet.en0") })
        #expect(result.changes.contains { $0.contains("homebrew.mxcl.socket_vmnet") })
        #expect(!result.commands.joined().contains("sudo brew"))
    }

    @Test func `live mutator records without touching the host`() throws {
        let recorder = RecordingSocketVmnetMutator()
        let result = try SocketVmnetApplyLive.run(
            request: SocketVmnetApplyRequest(action: .setup, interface: "en0"),
            probe: probe(),
            mutator: recorder,
        )
        #expect(result.applied)
        #expect(result.success)
        #expect(recorder.steps.contains { $0.contains("action=setup") })
        #expect(recorder.steps.contains { $0.contains("owned-launchd") })
        #expect(!recorder.steps.joined().contains("brew install"))
    }

    @Test func `uninstall keeps leftover helper plists and adds socket-vmnet cleanup`() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("scripts/uninstall.sh"),
            encoding: .utf8,
        )
        #expect(script.contains("dev.barkvisor.bridge.*.plist"))
        #expect(script.contains("dev.barkvisor.socket-vmnet.*.plist"))
        #expect(!script.contains("sudo brew install"))
        #expect(!script.contains("HelperXPCClient"))
    }
}
