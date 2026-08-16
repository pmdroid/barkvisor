import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Headless join helper (PAS-180)")
struct WorkerJoinTests {
    @Test func `local join URL is console loopback pairing join`() throws {
        let url = try LocalPairingJoin.localURL(port: 7_777)
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 7_777)
        #expect(url.path == "/api/pairing/join")
        #expect(LocalPairingJoin.path == "/api/pairing/join")
    }

    @Test func `local join URL is not built through the Home proxy`() throws {
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.localURL(port: 7_777, path: LocalPairingJoin.path)
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.rejectConsoleLocalOnly(LocalPairingJoin.path)
        }
        let url = try LocalPairingJoin.localURL(port: 7_777)
        #expect(url.absoluteString == "http://127.0.0.1:7777/api/pairing/join")
    }

    @Test func `join request sends the offer as qrPayload`() throws {
        let offer = "barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777"
        let request = try LocalPairingJoin.request(offer: "  \(offer)  ")
        #expect(request.qrPayload == offer)
        #expect(request.code == nil)
        #expect(throws: PairingError.invalidPayload("Pairing offer is required")) {
            try LocalPairingJoin.request(offer: "   ")
        }
        #expect(throws: PairingError.self) {
            try LocalPairingJoin.request(offer: "")
        }
    }

    @Test func `first-boot offer is ignored after setup or an existing pair`() {
        let env = [LocalPairingJoin.environmentKey: " barkvisor://pair/v1?code=ABCD "]
        #expect(
            LocalPairingJoin.firstBootOffer(
                environment: env,
                setupComplete: false,
                alreadyPaired: false,
            ) == "barkvisor://pair/v1?code=ABCD",
        )
        #expect(
            LocalPairingJoin.firstBootOffer(
                environment: env,
                setupComplete: true,
                alreadyPaired: false,
            ) == nil,
        )
        #expect(
            LocalPairingJoin.firstBootOffer(
                environment: env,
                setupComplete: false,
                alreadyPaired: true,
            ) == nil,
        )
        #expect(
            LocalPairingJoin.firstBootOffer(
                environment: [:],
                setupComplete: false,
                alreadyPaired: false,
            ) == nil,
        )
        #expect(
            LocalPairingJoin.firstBootOffer(
                environment: [LocalPairingJoin.environmentKey: "  "],
                setupComplete: false,
                alreadyPaired: false,
            ) == nil,
        )
    }

    @Test func `post sends JSON to the local join path`() async throws {
        let offer = "barkvisor://pair/v1?code=ABCD-EFGH"
        let expected = PairingJoinResponse(
            peerHostId: "peer-1",
            peerFingerprint: "aa",
            issuedFingerprint: "bb",
            agentPort: 7_778,
        )
        let body = try JSONEncoder().encode(expected)
        let client = RecordingJoinClient(response: PairingHTTPResponse(status: 200, body: body))
        let result = try await LocalPairingJoin.post(offer: offer, port: 7_777, client: client)
        #expect(result.peerHostId == "peer-1")
        #expect(client.lastURL?.absoluteString == "http://127.0.0.1:7777/api/pairing/join")
        let postedBody = try #require(client.lastBody)
        let posted = try JSONDecoder().decode(PairingJoinRequest.self, from: postedBody)
        #expect(posted.qrPayload == offer)
    }

    @Test func `post maps a non-success envelope`() async throws {
        let envelope = Data(#"{"error":true,"code":"forbidden","reason":"limited to this Device","status":403}"#.utf8)
        let client = RecordingJoinClient(response: PairingHTTPResponse(status: 403, body: envelope))
        await #expect(throws: PairingError.redeemFailed(
            status: 403,
            reason: "limited to this Device",
        )) {
            try await LocalPairingJoin.post(offer: "barkvisor://pair/v1?x=1", port: 7_777, client: client)
        }
    }

    @Test func `console-local join path stays rejected on the Home proxy`() {
        #expect(HomeDeviceProxy.isConsoleLocalOnly("/api/pairing/join"))
        #expect(HomeDeviceProxy.isConsoleLocalOnly("/api/pairing/join/extra"))
        #expect(!HomeDeviceProxy.isConsoleLocalOnly("/api/pairing/redeem"))
    }
}

private final class RecordingJoinClient: PairingHTTPClient, @unchecked Sendable {
    let response: PairingHTTPResponse
    private(set) var lastURL: URL?
    private(set) var lastBody: Data?

    init(response: PairingHTTPResponse) {
        self.response = response
    }

    func get(url: URL) async throws -> PairingHTTPResponse {
        lastURL = url
        return response
    }

    func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
        lastURL = url
        lastBody = body
        return response
    }
}
