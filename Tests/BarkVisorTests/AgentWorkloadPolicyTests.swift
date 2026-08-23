import Foundation
import Testing
@testable import BarkVisorCore

struct AgentWorkloadPolicyTests {
    @Test func `omitted class is house`() throws {
        #expect(try WorkloadClass.parse(nil) == .house)
        #expect(try WorkloadClass.parse("") == .house)
        #expect(try WorkloadClass.parse("  ") == .house)
    }

    @Test func `unknown class is 400`() {
        let err = #expect(throws: BarkVisorError.self) {
            _ = try WorkloadClass.parse("appliance")
        }
        #expect(err?.httpStatus == 400)
    }

    @Test func `agent rejects USB bridged forwards and shares`() {
        let usb = #expect(throws: BarkVisorError.self) {
            try AgentWorkloadPolicy.validate(
                workloadClass: .agent,
                usbCount: 1,
                sharedPathCount: 0,
                portForwardCount: 0,
                networkMode: .nat,
            )
        }
        #expect(usb?.httpStatus == 403)
        #expect(usb?.code == "forbidden")

        let lan = #expect(throws: BarkVisorError.self) {
            try AgentWorkloadPolicy.validate(
                workloadClass: .agent,
                usbCount: 0,
                sharedPathCount: 0,
                portForwardCount: 0,
                networkMode: .bridged,
            )
        }
        #expect(lan?.httpStatus == 403)

        let fwd = #expect(throws: BarkVisorError.self) {
            try AgentWorkloadPolicy.validate(
                workloadClass: .agent,
                usbCount: 0,
                sharedPathCount: 0,
                portForwardCount: 1,
                networkMode: .nat,
            )
        }
        #expect(fwd?.httpStatus == 403)
    }

    @Test func `agent allows NAT and isolated`() throws {
        try AgentWorkloadPolicy.validate(
            workloadClass: .agent,
            usbCount: 0,
            sharedPathCount: 0,
            portForwardCount: 0,
            networkMode: .nat,
        )
        try AgentWorkloadPolicy.validate(
            workloadClass: .agent,
            usbCount: 0,
            sharedPathCount: 0,
            portForwardCount: 0,
            networkMode: .isolated,
        )
    }

    @Test func `house is unconstrained`() throws {
        try AgentWorkloadPolicy.validate(
            workloadClass: .house,
            usbCount: 2,
            sharedPathCount: 1,
            portForwardCount: 3,
            networkMode: .bridged,
        )
    }

    @Test func `grant copy states WAN vs house`() {
        #expect(WorkloadClass.agent.grantCopy == "WAN yes, house no.")
        #expect(WorkloadClass.house.grantCopy.contains("LAN"))
    }
}
