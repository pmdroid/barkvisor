import Foundation
import Testing
@testable import BarkVisorConsole

struct SessionTests {
    private func jwt(exp: TimeInterval) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["exp": exp])
        var encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        encoded = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "e30.\(encoded).sig"
    }

    @Test func `expired jwt is detected without wiping policy helpers`() throws {
        let past = try jwt(exp: 1_700_000_000)
        let future = try jwt(exp: 1_900_000_000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(JWT.isExpired(past, now: now))
        #expect(!JWT.isExpired(future, now: now))
        #expect(JWT.needsRefresh(past, now: now))
        #expect(JWT.needsRefresh(future, now: Date(timeIntervalSince1970: 1_900_000_000 - 60)))
        #expect(!JWT.needsRefresh(future, now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(JWT.needsRefresh(nil, now: now))
    }

    @Test func `login response requires refresh token`() throws {
        let data = Data(#"{"token":"jwt-1","refreshToken":"bvrt_abc"}"#.utf8)
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        #expect(decoded.token == "jwt-1")
        #expect(decoded.refreshToken == "bvrt_abc")
    }

    @Test func `login uri is not pairing`() throws {
        let uri = "barkvisor://login/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777"
        let payload = try LoginURI.parse(uri)
        #expect(payload.code == "ABCD-EFGH")
        #expect(payload.host == "192.168.0.8")
        #expect(payload.port == 7_777)
        #expect(payload.deviceURL == "http://192.168.0.8:7777")
        #expect(throws: APIError.self) {
            try LoginURI.parse(
                "barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777&hostId=h&fp=abc",
            )
        }
        #expect(throws: APIError.self) {
            try LoginURI.parse("barkvisor://login/v1?code=ABCD-EFGH&host=8.8.8.8&port=7777")
        }
        #expect(LoginURI.isAllowedHost("10.0.0.4"))
        #expect(LoginURI.isAllowedHost("172.16.1.2"))
        #expect(LoginURI.isAllowedHost("100.64.0.8"))
        #expect(LoginURI.isAllowedHost("box.home.example"))
        #expect(!LoginURI.isAllowedHost("1.1.1.1"))
        #expect(!LoginURI.isAllowedHost("localhost"))
    }

    @Test func `device url origin compare is host and port only`() throws {
        let a = try DeviceURL.normalize("http://192.168.0.8:7777/login")
        let b = try DeviceURL.normalize("http://192.168.0.8:7777")
        let c = try DeviceURL.normalize("http://10.0.0.4:7777")
        #expect(DeviceURL.sameOrigin(a, b))
        #expect(!DeviceURL.sameOrigin(a, c))
    }
}
