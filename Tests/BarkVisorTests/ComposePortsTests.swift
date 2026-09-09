import Foundation
import Testing
@testable import BarkVisorCore

struct ComposePortsTests {
    @Test func `inspect HostIp must be the LAN address`() throws {
        let lan = "192.168.8.10"
        let data = Data(
            """
            [{"NetworkSettings":{"Ports":{
              "80/tcp":[{"HostIp":"192.168.8.10","HostPort":"8080"}],
              "1900/udp":[{"HostIp":"192.168.8.10","HostPort":"1900"}]
            }}}]
            """.utf8,
        )
        let bindings = try ComposePorts.parseInspectBindings(data)
        #expect(bindings.count == 2)
        #expect(bindings.contains {
            $0.hostIP == lan && $0.hostPort == 8_080 && $0.containerPort == 80 && $0.proto == "tcp"
        })
        #expect(bindings.contains {
            $0.hostIP == lan && $0.hostPort == 1_900 && $0.proto == "udp"
        })
        try ComposePorts.requireLANHostIP(
            bindings,
            bindHost: lan,
            expected: [
                PublishedPort(hostPort: 8_080, containerPort: 80, proto: "tcp", hostAddress: lan),
                PublishedPort(hostPort: 1_900, containerPort: 1_900, proto: "udp", hostAddress: lan),
            ],
            allowWildcard: false,
        )
    }

    @Test func `inspect wildcard HostIp is rejected on Linux proof`() throws {
        let data = Data(
            """
            [{"NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}}}]
            """.utf8,
        )
        let bindings = try ComposePorts.parseInspectBindings(data)
        let error = #expect(throws: BarkVisorError.self) {
            try ComposePorts.requireLANHostIP(
                bindings,
                bindHost: "192.168.8.10",
                expected: [PublishedPort(hostPort: 8_080, containerPort: 80, proto: "tcp")],
                allowWildcard: false,
            )
        }
        guard case let .internalError(message) = error else {
            Issue.record("expected internalError")
            return
        }
        #expect(message.contains("192.168.8.10"))
        #expect(message.contains("0.0.0.0"))
        try ComposePorts.requireLANHostIP(
            bindings,
            bindHost: "192.168.8.10",
            expected: [PublishedPort(hostPort: 8_080, containerPort: 80, proto: "tcp")],
            allowWildcard: true,
        )
    }

    @Test func `inspect must include every expected published port`() throws {
        let lan = "192.168.8.10"
        let data = Data(
            """
            [{"NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"192.168.8.10","HostPort":"8080"}]}}}]
            """.utf8,
        )
        let bindings = try ComposePorts.parseInspectBindings(data)
        let error = #expect(throws: BarkVisorError.self) {
            try ComposePorts.requireLANHostIP(
                bindings,
                bindHost: lan,
                expected: [
                    PublishedPort(hostPort: 8_080, containerPort: 80, proto: "tcp"),
                    PublishedPort(hostPort: 1_900, containerPort: 1_900, proto: "udp"),
                ],
                allowWildcard: false,
            )
        }
        guard case let .internalError(message) = error else {
            Issue.record("expected internalError")
            return
        }
        #expect(message.contains("1900/udp"))
        let empty = #expect(throws: BarkVisorError.self) {
            try ComposePorts.requireLANHostIP(
                [],
                bindHost: lan,
                expected: [PublishedPort(hostPort: 8_080, containerPort: 80, proto: "tcp")],
                allowWildcard: true,
            )
        }
        #expect(empty != nil)
    }

    @Test func `inspect IPv6 any HostIp is a wildcard`() throws {
        let data = Data(
            """
            [{"NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"::","HostPort":"8080"}]}}}]
            """.utf8,
        )
        let bindings = try ComposePorts.parseInspectBindings(data)
        let error = #expect(throws: BarkVisorError.self) {
            try ComposePorts.requireLANHostIP(
                bindings,
                bindHost: "192.168.8.10",
                expected: [PublishedPort(hostPort: 8_080, containerPort: 80, proto: "tcp")],
                allowWildcard: false,
            )
        }
        #expect(error != nil)
    }
}
