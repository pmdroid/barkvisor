import Foundation
import Testing
@testable import BarkVisorCore

struct SocketVmnetLaunchdTests {
    @Test func `label and paths are per interface`() throws {
        try validateBridgeName("en0")
        #expect(SocketVmnetLaunchd.label(interface: "en0") == "dev.barkvisor.socket-vmnet.en0")
        #expect(SocketVmnetLaunchd.socketPath(interface: "en0") == "/var/run/socket_vmnet.bridged.en0")
        #expect(SocketVmnetLaunchd.socketPathsToRemove(interface: "en0").contains("/var/run/socket_vmnet.bridged.en0"))
        #expect(SocketVmnetLaunchd.socketPathsToRemove(interface: "en0").contains(
            "/opt/homebrew/var/run/socket_vmnet.bridged.en0",
        ))
        #expect(
            SocketVmnetLaunchd.plistURL(interface: "en1").path
                == "/Library/LaunchDaemons/dev.barkvisor.socket-vmnet.en1.plist",
        )
        #expect(!SocketVmnetLaunchd.labelPrefix.contains("helper"))
        #expect(!SocketVmnetLaunchd.labelPrefix.contains("Helper"))
    }

    @Test func `plist is a launchd job not an XPC helper`() {
        let xml = SocketVmnetLaunchd.plistXML(
            interface: "en0",
            binary: "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet",
            socketPath: "/var/run/socket_vmnet.bridged.en0",
        )
        #expect(xml.contains("<string>dev.barkvisor.socket-vmnet.en0</string>"))
        #expect(xml.contains("--vmnet-mode=bridged"))
        #expect(xml.contains("--vmnet-interface=en0"))
        #expect(xml.contains("/var/run/socket_vmnet.bridged.en0"))
        #expect(xml.contains("/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet"))
        #expect(!xml.contains("MachServices"))
        #expect(!xml.contains("HelperXPCClient"))
        #expect(!xml.contains("BarkVisorHelper"))
        #expect(!xml.contains("SMJobBless"))
        #expect(!xml.contains("PrivilegedHelperTools"))
    }

    @Test func `launchctl argv is bootstrap and bootout only`() {
        #expect(
            SocketVmnetLaunchd.bootoutArguments(label: "dev.barkvisor.socket-vmnet.en0")
                == ["bootout", "system/dev.barkvisor.socket-vmnet.en0"],
        )
        #expect(
            SocketVmnetLaunchd.bootstrapArguments(plistPath: "/tmp/x.plist")
                == ["bootstrap", "system", "/tmp/x.plist"],
        )
        #expect(
            SocketVmnetLaunchd.kickstartArguments(label: "dev.barkvisor.socket-vmnet.en0")
                == ["kickstart", "-k", "system/dev.barkvisor.socket-vmnet.en0"],
        )
        #expect(
            SocketVmnetLaunchd.printArguments(label: "homebrew.mxcl.socket_vmnet")
                == ["print", "system/homebrew.mxcl.socket_vmnet"],
        )
        #expect(SocketVmnetLaunchd.brewServicesStartArguments() == ["services", "start", "socket_vmnet"])
        #expect(SocketVmnetLaunchd.brewServicesStopArguments() == ["services", "stop", "socket_vmnet"])
        #expect(!SocketVmnetLaunchd.brewServicesStartArguments().contains("install"))
        #expect(SocketVmnetLaunchd.homebrewServiceLabel == "homebrew.mxcl.socket_vmnet")
    }

    @Test func `hostnet rollback launchd is a one-shot sleep then expire`() {
        #expect(HostNetworkRollbackLaunchd.label(target: "en0") == "dev.barkvisor.hostnet-rollback.en0")
        #expect(
            HostNetworkRollbackLaunchd.plistURL(target: "en0").path
                == "/Library/LaunchDaemons/dev.barkvisor.hostnet-rollback.en0.plist",
        )
        let helper = HostNetworkRollbackLaunchd.helperScript(
            binary: "/usr/local/bin/barkvisor",
            seconds: 60,
        )
        #expect(helper.contains("sleep 60"))
        #expect(helper.contains("hostnet-expire"))
        let xml = HostNetworkRollbackLaunchd.plistXML(
            target: "en0",
            helperPath: "/var/lib/barkvisor/host-network/en0-rollback.sh",
        )
        #expect(xml.contains("dev.barkvisor.hostnet-rollback.en0"))
        #expect(xml.contains("/bin/sh"))
        #expect(xml.contains("<false/>"))
        #expect(!xml.contains("MachServices"))
    }

    @Test func `install hint never says sudo brew install`() {
        #expect(SocketVmnetDiscovery.installHint.contains("brew install socket_vmnet"))
        #expect(SocketVmnetDiscovery.installHint.contains("do not sudo brew install"))
        #expect(!SocketVmnetDiscovery.installHint.contains("sudo brew services"))
        #expect(!SocketVmnetDiscovery.installHint.contains("sudo brew install socket"))
    }
}
