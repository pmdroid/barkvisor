import Foundation
import Testing
@testable import BarkVisorCore

struct AgentNetworkCageTests {
    @Test func `NAT extras black-hole daemon ports and disable ipv6`() {
        let extra = AgentNetworkCage.slirpExtras(mode: .nat)
        #expect(extra.contains("ipv6=off"))
        #expect(extra.contains("guestfwd=tcp:10.0.2.2:\(Config.port)-cmd:true"))
        #expect(extra.contains("guestfwd=tcp:10.0.2.2:\(Config.agentPort)-cmd:true"))
        #expect(!extra.contains("11434"))
        #expect(AgentNetworkCage.slirpExtras(mode: .isolated).isEmpty)
    }

    @Test func `host ollama guestfwd is opt-in`() {
        let extra = AgentNetworkCage.slirpExtras(mode: .nat, allowHostOllama: true)
        #expect(
            extra.contains(
                "guestfwd=tcp:10.0.2.2:\(AgentNetworkCage.ollamaPort)-tcp:127.0.0.1:\(AgentNetworkCage.ollamaPort)",
            ),
        )
        #expect(!AgentNetworkCage.allowHostOllama(userData: nil))
        #expect(!AgentNetworkCage.allowHostOllama(userData: "packages:\n  - git\n"))
        #expect(!AgentNetworkCage.allowHostOllama(userData: "# see 10.0.2.2:11434 in a comment\npackages:\n  - git\n"))
        #expect(!AgentNetworkCage.allowHostOllama(userData: "# barkvisor_allow_host_ollama: true\npackages:\n  - git\n"))
        #expect(
            AgentNetworkCage.allowHostOllama(
                userData: "export OPENAI_BASE_URL=\"http://10.0.2.2:11434/v1\"",
            ),
        )
        #expect(
            AgentNetworkCage.allowHostOllama(
                userData: "export OPENAI_BASE_URL='http://10.0.2.2:11434/v1'",
            ),
        )
        #expect(
            AgentNetworkCage.allowHostOllama(
                userData: "\(AgentNetworkCage.allowHostOllamaYAML)\npackage_update: true\n",
            ),
        )
        let open = AgentNetworkCage.seatbeltProfile(allowHostOllama: true)
        let ollamaAllow =
            "(allow network-outbound (remote tcp \"127.0.0.1:\(AgentNetworkCage.ollamaPort)\"))"
        #expect(open.contains(ollamaAllow))
        #expect(open.contains("224.0.0.0/4\"))\n\(ollamaAllow)"))
        #expect(!open.contains("224.0.0.0/4\"))(allow"))
        #expect(!AgentNetworkCage.seatbeltProfile.contains("127.0.0.1:\(AgentNetworkCage.ollamaPort)"))
    }

    @Test func `seatbelt denies RFC1918 and loopback`() {
        let profile = AgentNetworkCage.seatbeltProfile
        for cidr in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8"] {
            #expect(profile.contains(cidr))
        }
        #expect(profile.contains("(remote udp \"*:53\")"))
        #expect(!profile.contains("127.0.0.1:11434"))
    }

    @Test func `linux owner commands cover blocked CIDRs`() {
        let cmds = AgentNetworkCage.linuxOwnerRejectCommands(uid: 4_242)
        #expect(cmds.count == AgentNetworkCage.blockedIPv4CIDRs.count)
        #expect(cmds.allSatisfy { $0.contains("--uid-owner") && $0.contains("4242") && $0.contains("REJECT") })
        #expect(cmds.allSatisfy { !$0.contains("--pid-owner") })
        let deletes = AgentNetworkCage.linuxOwnerDeleteCommands(uid: 4_242)
        #expect(deletes.count == cmds.count)
        #expect(deletes.allSatisfy { $0.contains("-D") && $0.contains("OUTPUT") })
        #expect(AgentNetworkCage.iptablesSearchPaths.contains("/usr/bin/iptables"))
        #expect(AgentNetworkCage.iptablesSearchPaths.contains("/usr/sbin/iptables"))
        let accept = AgentNetworkCage.linuxOllamaAcceptCommands(uid: 4_242)
        #expect(accept.count == 1)
        #expect(accept[0].contains("11434"))
        #expect(accept[0].contains("ACCEPT"))
        #expect(accept[0].contains("127.0.0.1"))
    }

    @Test func `owner uid is the drop user or nil for root`() {
        #expect(
            AgentNetworkCage.workloadOwnerUID(
                euid: 0,
                dropsOnPlatform: true,
                uidForUser: { $0 == "barkvisor" ? 995 : nil },
            ) == 995,
        )
        #expect(
            AgentNetworkCage.workloadOwnerUID(
                euid: 0,
                dropsOnPlatform: true,
                uidForUser: { $0 == "qemu" ? 994 : nil },
            ) == 994,
        )
        #expect(
            AgentNetworkCage.workloadOwnerUID(
                euid: 0,
                dropsOnPlatform: true,
                uidForUser: { _ in nil },
            ) == nil,
        )
    }

    @Test func `house launch is not wrapped`() throws {
        let launch = QEMULaunchConfig(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["-version"],
            swtpmExecutable: nil,
            swtpmArguments: nil,
            swtpmStateDir: nil,
        )
        let wrapped = try AgentNetworkCage.wrapLaunch(launch, workloadClass: .house)
        #expect(wrapped.executable == launch.executable)
        #expect(wrapped.arguments == launch.arguments)
    }

    @Test func `agent NAT netdev includes cage extras`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "cage"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 1, memoryMb: 512),
                networks: [WorkloadNetwork(mode: "nat")],
                workloadClass: "agent",
            ),
        )
        let (args, wrap) = try QEMUBuilder.networkArgs(spec: spec, network: nil)
        #expect(!wrap)
        let netdev = args.first { $0.hasPrefix("user,id=net0") }
        #expect(netdev?.contains("ipv6=off") == true)
        #expect(netdev?.contains("guestfwd=tcp:10.0.2.2") == true)
        #expect(netdev?.contains("11434") != true)
        #expect(netdev?.contains("restrict=on") != true)

        let (ollamaArgs, _) = try QEMUBuilder.networkArgs(
            spec: spec, network: nil, allowHostOllama: true,
        )
        let ollamaNet = ollamaArgs.first { $0.hasPrefix("user,id=net0") }
        #expect(ollamaNet?.contains("11434") == true)
    }

    @Test func `cgroup name sanitization keeps safe characters`() {
        #expect(AgentNetworkCage.sanitizeCgroupName("vm-01_UUID.x") == "vm-01_UUID.x")
        #expect(AgentNetworkCage.sanitizeCgroupName("a/b\\c d") == "a-b-c-d")
        #expect(AgentNetworkCage.sanitizeCgroupName("") == "vm")
        #expect(AgentNetworkCage.cgroupRelPath(vmID: "abc") == "barkvisor-agent/abc")
    }

    @Test func `cgroup commands match by path and never by uid`() {
        let reject = AgentNetworkCage.linuxCgroupRejectCommands(cgroupRelPath: "barkvisor-agent/vm1")
        #expect(reject.count == AgentNetworkCage.blockedIPv4CIDRs.count)
        #expect(reject.allSatisfy { $0.contains("-m") && $0.contains("cgroup") && $0.contains("--path") })
        #expect(reject.allSatisfy { $0.contains("barkvisor-agent/vm1") && $0.contains("REJECT") })
        #expect(reject.allSatisfy { !$0.contains("--uid-owner") })

        let accept = AgentNetworkCage.linuxCgroupOllamaAcceptCommands(cgroupRelPath: "barkvisor-agent/vm1")
        #expect(accept.count == 1)
        #expect(accept[0].contains("11434") && accept[0].contains("ACCEPT"))

        let deletes = AgentNetworkCage.linuxCgroupDeleteCommands(cgroupRelPath: "barkvisor-agent/vm1")
        #expect(deletes.count == reject.count + accept.count)
        #expect(deletes.allSatisfy { $0.contains("-D") })
    }

    @Test func `placeInCgroup writes pid when root and dir is writable`() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(AgentNetworkCage.placeInCgroup(pid: 4_242, relPath: "barkvisor-agent/vm1", root: tmp.path, isRoot: true))
        let procs = try String(
            contentsOf: tmp.appendingPathComponent("barkvisor-agent/vm1/cgroup.procs"),
            encoding: .utf8,
        )
        #expect(procs.trimmingCharacters(in: .whitespacesAndNewlines) == "4242")
        #expect(!AgentNetworkCage.placeInCgroup(pid: 4_242, relPath: "barkvisor-agent/vm1", root: tmp.path, isRoot: false))
        AgentNetworkCage.removeCgroup(relPath: "barkvisor-agent/vm1", root: tmp.path)
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("barkvisor-agent/vm1").path))
    }

    @Test func `reconcile re-applies reject and ollama only when a remaining VM opts in`() {
        let rejectOnly = AgentNetworkCage.reconcileCommands(
            uid: 995,
            remainingAgentVMs: ["vm2"],
            userDataLookup: { _ in nil },
        )
        #expect(rejectOnly == AgentNetworkCage.linuxOwnerRejectCommands(uid: 995))
        #expect(rejectOnly.allSatisfy { $0.contains("--uid-owner") && !$0.contains("--pid-owner") })

        let withOllama = AgentNetworkCage.reconcileCommands(
            uid: 995,
            remainingAgentVMs: ["vm2", "vm3"],
            userDataLookup: { $0 == "vm3" ? "\(AgentNetworkCage.allowHostOllamaYAML)\n" : nil },
        )
        #expect(withOllama.count == rejectOnly.count + 1)
        #expect(withOllama.last?.contains("11434") == true)
    }
}
