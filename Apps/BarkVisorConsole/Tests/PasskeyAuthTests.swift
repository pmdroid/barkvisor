import Foundation
import Testing

@testable import BarkVisorConsole

struct PasskeyAuthTests {
    @Test func base64urlRoundTrip() {
        let raw = Data([0, 1, 2, 250, 251, 252, 253, 254, 255])
        let encoded = PasskeySupport.base64urlFromData(raw)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(PasskeySupport.dataFromBase64url(encoded) == raw)
    }

    @Test func blocksRawIPHost() {
        let url = URL(string: "http://192.168.1.10:7777")!
        #expect(PasskeySupport.passkeyBlock(for: url) != nil)
    }

    @Test func allowsLocalhost() {
        let url = URL(string: "http://localhost:7777")!
        #expect(PasskeySupport.passkeyBlock(for: url) == nil)
    }

    @Test func assertionJSONShape() {
        let json = PasskeySupport.assertionCredentialJSON(
            id: "abc",
            rawID: Data([1, 2, 3]),
            clientDataJSON: Data([4]),
            authenticatorData: Data([5]),
            signature: Data([6]),
            userHandle: Data([7]),
        )
        #expect(json["type"] as? String == "public-key")
        #expect(json["id"] as? String == "abc")
        let response = json["response"] as? [String: Any]
        #expect(response?["clientDataJSON"] as? String != nil)
        #expect(response?["userHandle"] as? String != nil)
    }
}
