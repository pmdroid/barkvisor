import Foundation
import Testing
@testable import BarkVisorConsole

struct PairingOfferTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    @Test func `issue pairing request omits empty host`() throws {
        let empty = try encoder.encode(IssuePairingRequest(advertisedHost: nil))
        #expect(String(data: empty, encoding: .utf8) == "{}")
        let blank = try encoder.encode(IssuePairingRequest(advertisedHost: ""))
        #expect(String(data: blank, encoding: .utf8) == "{}")
        let picked = try encoder.encode(IssuePairingRequest(advertisedHost: "100.64.0.8"))
        let object = try decoder.decode(IssuePairingJSON.self, from: picked)
        #expect(object.advertisedHost == "100.64.0.8")
    }

    @Test func `pairing issue decodes advertised hosts`() throws {
        let json = """
        {
          "code": "ABCD-EFGH",
          "expiresAt": "2026-08-16T22:10:00.000Z",
          "ttlSeconds": 600,
          "qrPayload": "barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777&hostId=h&fp=abc",
          "hostId": "h",
          "fingerprint": "abc",
          "caFingerprint": "ca",
          "port": 7777,
          "agentPort": 7778,
          "advertisedHost": "box.home.example",
          "advertisedHosts": ["192.168.0.8", "100.64.0.8"],
          "apiVersion": 1
        }
        """.data(using: .utf8)!
        let offer = try decoder.decode(PairingIssue.self, from: json)
        #expect(offer.code == "ABCD-EFGH")
        #expect(offer.advertisedHost == "box.home.example")
        #expect(offer.advertisedHosts == ["192.168.0.8", "100.64.0.8"])
        #expect(PairingAdvertisedHost.issuedHost(offer) == "box.home.example")
        #expect(
            PairingAdvertisedHost.pairingHost(fromPayload: offer.qrPayload) == "192.168.0.8",
        )
    }

    @Test func `advertised host picker matches web settings`() {
        #expect(PairingAdvertisedHost.customSentinel == "__custom__")
        #expect(PairingAdvertisedHost.hostForOffer(selectedHost: "100.64.0.8", customHost: "ignored.example") == "100.64.0.8")
        #expect(
            PairingAdvertisedHost.hostForOffer(
                selectedHost: PairingAdvertisedHost.customSentinel,
                customHost: "  box.home.example  ",
            ) == "box.home.example",
        )
        #expect(
            PairingAdvertisedHost.hostForOffer(
                selectedHost: PairingAdvertisedHost.customSentinel,
                customHost: "   ",
            ) == nil,
        )
        #expect(
            PairingAdvertisedHost.pairingHost(
                fromPayload: "barkvisor://pair/v1?code=ABCD-EFGH&host=100.64.0.8&port=7777&hostId=h&fp=abc",
            ) == "100.64.0.8",
        )
        let listed = offer(advertisedHost: "192.168.0.8", hosts: ["192.168.0.8", "100.64.0.8"])
        #expect(PairingAdvertisedHost.syncPicker(from: listed) == .init(selectedHost: "192.168.0.8", customHost: ""))
        let named = offer(advertisedHost: "box.home.example", hosts: ["192.168.0.8"])
        #expect(
            PairingAdvertisedHost.syncPicker(from: named)
                == .init(selectedHost: PairingAdvertisedHost.customSentinel, customHost: "box.home.example"),
        )
        #expect(PairingAdvertisedHost.syncPicker(from: nil) == .init(selectedHost: "", customHost: ""))
        let fromURI = offer(advertisedHost: nil, hosts: ["192.168.0.8"])
        #expect(PairingAdvertisedHost.issuedHost(fromURI) == "192.168.0.8")
    }

    @Test func `picker restore after unchanged reload keeps custom DNS`() {
        let live = offer(advertisedHost: "box.home.example", hosts: ["192.168.0.8"])
        let reloaded = live
        #expect(reloaded == live)
        // SettingsView is destroyed on leave; @State starts empty while AppModel still holds `live`.
        var picker = PairingAdvertisedHost.Picker(selectedHost: "", customHost: "")
        picker = PairingAdvertisedHost.syncPicker(from: reloaded)
        #expect(
            picker == .init(selectedHost: PairingAdvertisedHost.customSentinel, customHost: "box.home.example"),
        )
    }

    @Test func `changing host reissues unless unchanged or custom pending`() {
        #expect(PairingAdvertisedHost.applyListedHost(PairingAdvertisedHost.customSentinel, currentIssued: "192.168.0.8") == .skip)
        #expect(PairingAdvertisedHost.applyListedHost("192.168.0.8", currentIssued: "192.168.0.8") == .skip)
        #expect(PairingAdvertisedHost.applyListedHost("100.64.0.8", currentIssued: "192.168.0.8") == .issue("100.64.0.8"))
        #expect(PairingAdvertisedHost.applyListedHost("1.1.1.1", currentIssued: nil) == .rejectedHost)
        #expect(PairingAdvertisedHost.applyListedHost("localhost", currentIssued: nil) == .rejectedHost)
        #expect(PairingAdvertisedHost.applyCustomHost("   ", currentIssued: nil) == .needCustomHost)
        #expect(PairingAdvertisedHost.applyCustomHost("box.home.example", currentIssued: "box.home.example") == .skip)
        #expect(PairingAdvertisedHost.applyCustomHost("  nas  ", currentIssued: "192.168.0.8") == .issue("nas"))
        #expect(PairingAdvertisedHost.applyCustomHost("8.8.8.8", currentIssued: nil) == .rejectedHost)
        let hosts = ["studio.local", "192.168.0.8", "100.64.0.8", "box.tailnet.ts.net"]
        #expect(
            PairingAdvertisedHost.syncAdvertisePicker(advertiseUrl: "192.168.0.8", listedHosts: hosts)
                == .init(selectedHost: "192.168.0.8", customHost: ""),
        )
        #expect(
            PairingAdvertisedHost.syncAdvertisePicker(
                advertiseUrl: "box.tailnet.ts.net", listedHosts: hosts,
            ) == .init(selectedHost: "box.tailnet.ts.net", customHost: ""),
        )
        #expect(
            PairingAdvertisedHost.syncAdvertisePicker(advertiseUrl: "home.ts.net", listedHosts: hosts)
                == .init(selectedHost: PairingAdvertisedHost.customSentinel, customHost: "home.ts.net"),
        )
        #expect(
            PairingAdvertisedHost.syncAdvertisePicker(advertiseUrl: nil, listedHosts: hosts)
                == .init(selectedHost: PairingAdvertisedHost.customSentinel, customHost: ""),
        )
        #expect(PairingAdvertisedHost.hostForOffer(selectedHost: "100.64.0.8", customHost: "") == "100.64.0.8")
        #expect(
            PairingAdvertisedHost.hostForOffer(
                selectedHost: PairingAdvertisedHost.customSentinel, customHost: "  nas.home  ",
            ) == "nas.home",
        )
        #expect(
            PairingAdvertisedHost.hostForOffer(
                selectedHost: PairingAdvertisedHost.customSentinel, customHost: "",
            ) == nil,
        )
        #expect(LoginURI.isAllowedHost("10.0.0.4"))
        #expect(LoginURI.isAllowedHost("172.16.1.2"))
        #expect(LoginURI.isAllowedHost("100.64.0.8"))
        #expect(LoginURI.isAllowedHost("box.home.example"))
        #expect(LoginURI.isAllowedHost("fd12:3456:789a::1"))
        #expect(!LoginURI.isAllowedHost("1.1.1.1"))
        #expect(!LoginURI.isAllowedHost("127.1"))
    }

    @Test func `pairing qr encodes payload and skips empty`() {
        let payload = "barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777&hostId=h&fp=abc"
        let image = PairingQR.image(payload: payload)
        #expect(image != nil)
        #expect(image?.width ?? 0 >= 196)
        #expect(PairingQR.image(payload: "   ") == nil)
        #expect(PairingExpiry.isActive(expiresAt: "2026-08-16T22:10:00.000Z", now: iso("2026-08-16T22:00:00.000Z")))
        #expect(!PairingExpiry.isActive(expiresAt: "2026-08-16T22:10:00.000Z", now: iso("2026-08-16T22:10:00.000Z")))
    }

    @Test func `pairing qr reuses cgimage for the same payload`() {
        let payload = "barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777&hostId=h&fp=abc"
        let first = PairingQR.image(payload: payload)
        let second = PairingQR.image(payload: payload)
        let other = PairingQR.image(payload: payload + "&x=1")
        #expect(first != nil)
        #expect(second != nil)
        #expect(other != nil)
        #expect(first === second)
        #expect(first !== other)
    }

    private func iso(_ raw: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)!
    }

    private func offer(advertisedHost: String?, hosts: [String]) -> PairingIssue {
        PairingIssue(
            code: "ABCD-EFGH",
            expiresAt: "2026-08-16T22:10:00.000Z",
            ttlSeconds: 600,
            qrPayload: "barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777",
            hostId: "h",
            fingerprint: "abc",
            caFingerprint: "ca",
            port: 7_777,
            agentPort: 7_778,
            advertisedHost: advertisedHost,
            advertisedHosts: hosts,
            apiVersion: 1,
        )
    }
}

private struct IssuePairingJSON: Decodable {
    var advertisedHost: String?
}
