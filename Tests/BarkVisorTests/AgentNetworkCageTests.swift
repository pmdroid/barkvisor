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
        #expect(AgentNetworkCage.allowHostOllama(userData: "OPENAI_BASE_URL=\"http://10.0.2.2:11434/v1\""))
        let open = AgentNetworkCage.seatbeltProfile(allowHostOllama: true)
        #expect(open.contains("127.0.0.1:11434"))
        #expect(!AgentNetworkCage.seatbeltProfile.contains("127.0.0.1:11434"))
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
        let cmds = AgentNetworkCage.linuxOwnerRejectCommands(pid: 4_242)
        #expect(cmds.count == AgentNetworkCage.blockedIPv4CIDRs.count)
        #expect(cmds.allSatisfy { $0.contains("4242") && $0.contains("REJECT") })
        let deletes = AgentNetworkCage.linuxOwnerDeleteCommands(pid: 4_242)
        #expect(deletes.count == cmds.count)
        #expect(deletes.allSatisfy { $0.contains("-D") && $0.contains("OUTPUT") })
        #expect(AgentNetworkCage.iptablesSearchPaths.contains("/usr/bin/iptables"))
        #expect(AgentNetworkCage.iptablesSearchPaths.contains("/usr/sbin/iptables"))
        let accept = AgentNetworkCage.linuxOllamaAcceptCommands(pid: 4_242)
        #expect(accept.count == 1)
        #expect(accept[0].contains("11434"))
        #expect(accept[0].contains("ACCEPT"))
        #expect(accept[0].contains("127.0.0.1"))
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
}
