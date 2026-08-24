import Foundation
import Testing
@testable import BarkVisorConsole

struct InferenceAPIHowToTests {
    @Test func `self uses connected home origin not device ollama`() {
        let howTo = InferenceAPIHowTo.snippets(
            role: .thisDevice,
            originHost: "192.168.30.1",
            originPort: 7_777,
            originScheme: "http",
            memberHost: nil,
            grantPlaintext: nil,
        )
        #expect(howTo.lanBaseURL == "http://192.168.30.1:7777/v1")
        #expect(howTo.lanCompletionsURL == "http://192.168.30.1:7777/v1/chat/completions")
        #expect(howTo.curl.contains("Authorization: Bearer <inference-key>"))
        #expect(howTo.env.contains("export OPENAI_BASE_URL='http://192.168.30.1:7777/v1'"))
        #expect(!howTo.curl.contains(":11434"))
        #expect(!howTo.env.contains(":11434"))
        #expect(howTo.lanCompletionsURL.contains(":7777"))
    }

    @Test func `member uses advertised host on listen port`() {
        let howTo = InferenceAPIHowTo.snippets(
            role: .member,
            originHost: "192.168.30.1",
            originPort: 8_443,
            originScheme: "https",
            memberHost: "10.0.0.8",
            grantPlaintext: nil,
        )
        #expect(howTo.lanBaseURL == "http://10.0.0.8:7777/v1")
        #expect(!howTo.lanCompletionsURL.contains(":11434"))
        #expect(!howTo.lanCompletionsURL.contains(":8443"))
        #expect(!howTo.lanCompletionsURL.contains(":7778"))
        #expect(
            InferenceAPIHowTo.lanListenPort(role: .member, originPort: 8_443, memberHost: "10.0.0.8")
                == DeviceURL.defaultPort,
        )
    }

    @Test func `member without host falls back to origin`() {
        let howTo = InferenceAPIHowTo.snippets(
            role: .member,
            originHost: "home.local",
            originPort: 7_777,
            originScheme: "http",
            memberHost: "  ",
            grantPlaintext: nil,
        )
        #expect(howTo.lanBaseURL == "http://home.local:7777/v1")
    }

    @Test func `grant plaintext replaces placeholder`() {
        let howTo = InferenceAPIHowTo.snippets(
            role: .thisDevice,
            origin: URL(string: "http://127.0.0.1:7777"),
            memberHost: nil,
            grantPlaintext: " barkvisor_abc ",
        )
        #expect(howTo.apiKey == "barkvisor_abc")
        #expect(howTo.curl.contains("Authorization: Bearer barkvisor_abc"))
        #expect(howTo.env.contains("export OPENAI_API_KEY='barkvisor_abc'"))
        #expect(howTo.cageEnv.contains("export OPENAI_API_KEY='barkvisor_abc'"))
    }

    @Test func `cage block is slirp guestfwd and dns`() {
        let howTo = InferenceAPIHowTo.snippets(
            role: .thisDevice,
            originHost: "192.168.30.1",
            originPort: 7_777,
            originScheme: "http",
            memberHost: nil,
            grantPlaintext: nil,
        )
        #expect(howTo.cageBaseURL == "http://10.0.2.2:11434/v1")
        #expect(howTo.cageEnv.contains("export OPENAI_BASE_URL='http://10.0.2.2:11434/v1'"))
        #expect(howTo.cageDnsLine == InferenceAPIHowTo.cageDnsLine)
        #expect(!howTo.cageDnsLine.lowercased().contains("mtls"))
        #expect(!howTo.cageDnsLine.lowercased().contains("cidr"))
        #expect(howTo.cageBaseURL == CodingAgentImage.homeOllamaGrantURL)
    }

    @Test func `ipv 6 origin is bracketed cage stays I pv 4`() {
        let howTo = InferenceAPIHowTo.snippets(
            role: .thisDevice,
            originHost: "2001:db8::1",
            originPort: 7_777,
            originScheme: "http",
            memberHost: nil,
            grantPlaintext: nil,
        )
        #expect(howTo.lanBaseURL == "http://[2001:db8::1]:7777/v1")
        #expect(howTo.cageBaseURL == "http://10.0.2.2:11434/v1")
    }
}
