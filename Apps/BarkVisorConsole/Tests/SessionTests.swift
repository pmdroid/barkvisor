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
        #expect(LoginURI.isAllowedHost("nas"))
        #expect(LoginURI.isAllowedHost("fd12:3456:789a::1"))
        #expect(!LoginURI.isAllowedHost("1.1.1.1"))
        #expect(!LoginURI.isAllowedHost("localhost"))
        #expect(!LoginURI.isAllowedHost("127.1"))
        #expect(!LoginURI.isAllowedHost("fd00:ec2::254"))
        let named = try LoginURI.parse("barkvisor://login/v1?code=ABCD-EFGH&host=nas&port=7777")
        #expect(named.host == "nas")
        let ula = try LoginURI.parse(
            "barkvisor://login/v1?code=ABCD-EFGH&host=fd12:3456:789a::1&port=7777",
        )
        #expect(ula.host == "fd12:3456:789a::1")
        #expect(ula.deviceURL == "http://[fd12:3456:789a::1]:7777")
    }

    @Test func `refresh drops the session only on 401`() {
        #expect(SessionRefreshResult.from(error: APIError.unauthorized) == .unauthorized)
        #expect(SessionRefreshResult.from(error: APIError.http(status: 401, reason: "expired")) == .unauthorized)
        #expect(SessionRefreshResult.from(error: APIError.transport("offline")) != .unauthorized)
        #expect(SessionRefreshResult.from(error: APIError.http(status: 503, reason: "down")) != .unauthorized)
        #expect(SessionRefreshResult.from(error: APIError.http(status: 500, reason: "boom")) != .unauthorized)
        if case let .unavailable(message) = SessionRefreshResult.from(error: APIError.transport("offline")) {
            #expect(message == "offline")
        } else {
            Issue.record("transport refresh must stay unavailable")
        }
        #expect(APIClient.retryAfter401(.rotated("jwt-2")) == .retry("jwt-2"))
        #expect(APIClient.retryAfter401(.unauthorized) == .fail(.unauthorized))
        #expect(APIClient.retryAfter401(.unavailable("offline")) == .fail(.transport("offline")))
        #expect(APIClient.retryAfter401(.unavailable("down")) != .fail(.unauthorized))
    }

    @Test func `qr scanner maps camera failures to a banner`() {
        #expect(LoginQRScanError.failure(authorized: false, cameraPresent: true) == .cameraDenied)
        #expect(LoginQRScanError.failure(authorized: true, cameraPresent: false) == .cameraUnavailable)
        #expect(LoginQRScanError.failure(authorized: true, cameraPresent: true) == nil)
        #expect(LoginQRScanError.cameraDenied.rawValue == "Camera access is required to scan a sign-in QR")
    }

    @Test func `device url origin compare is host and port only`() throws {
        let a = try DeviceURL.normalize("http://192.168.0.8:7777/login")
        let b = try DeviceURL.normalize("http://192.168.0.8:7777")
        let c = try DeviceURL.normalize("http://10.0.0.4:7777")
        #expect(DeviceURL.sameOrigin(a, b))
        #expect(!DeviceURL.sameOrigin(a, c))
    }

    @Test func `login offer write is dropped after session generation bump`() throws {
        let origin = try DeviceURL.normalize("http://192.168.0.8:7777")
        let other = try DeviceURL.normalize("http://10.0.0.4:7777")
        #expect(
            LoginOfferSession.stillCurrent(
                generation: 3,
                currentGeneration: 3,
                origin: origin,
                currentOrigin: origin,
                token: "jwt-1",
                currentToken: "jwt-1",
            ),
        )
        #expect(
            !LoginOfferSession.stillCurrent(
                generation: 3,
                currentGeneration: 4,
                origin: origin,
                currentOrigin: origin,
                token: "jwt-1",
                currentToken: "jwt-1",
            ),
        )
        #expect(
            !LoginOfferSession.stillCurrent(
                generation: 3,
                currentGeneration: 3,
                origin: origin,
                currentOrigin: other,
                token: "jwt-1",
                currentToken: "jwt-1",
            ),
        )
        #expect(
            !LoginOfferSession.stillCurrent(
                generation: 3,
                currentGeneration: 3,
                origin: origin,
                currentOrigin: origin,
                token: "jwt-1",
                currentToken: nil,
            ),
        )
    }

    @Test func `login offer advertised host is omitted without a pairing picker`() {
        #expect(LoginOfferHost.advertisedHost(pickerSelection: "192.168.0.8", pickerAvailable: false) == nil)
        #expect(LoginOfferHost.advertisedHost(pickerSelection: "  nas  ", pickerAvailable: true) == "nas")
        #expect(LoginOfferHost.advertisedHost(pickerSelection: "  ", pickerAvailable: true) == nil)
        #expect(LoginOfferHost.advertisedHost(pickerSelection: nil, pickerAvailable: true) == nil)
    }

    @Test func `login offer issue request omits empty advertised host`() throws {
        let encoder = JSONEncoder()
        let empty = try encoder.encode(LoginOfferIssueRequest(advertisedHost: nil))
        #expect(String(data: empty, encoding: .utf8) == "{}")
        let blank = try encoder.encode(LoginOfferIssueRequest(advertisedHost: "  "))
        #expect(String(data: blank, encoding: .utf8) == "{}")
        let stamped = try encoder.encode(LoginOfferIssueRequest(advertisedHost: " 192.168.0.8 "))
        #expect(String(data: stamped, encoding: .utf8) == #"{"advertisedHost":"192.168.0.8"}"#)
    }

    @Test func `login offer json is a sign-in uri with a qr`() throws {
        let json = Data(
            #"{"code":"ABCD-EFGH","expiresAt":"2026-08-16T22:10:00.000Z","ttlSeconds":180,"uri":"barkvisor://login/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777","host":"192.168.0.8","port":7777}"#
                .utf8,
        )
        let offer = try JSONDecoder().decode(LoginOfferIssue.self, from: json)
        #expect(offer.code == "ABCD-EFGH")
        #expect(offer.ttlSeconds == 180)
        #expect(offer.port == 7_777)
        let payload = try LoginURI.parse(offer.uri)
        #expect(payload.code == offer.code)
        #expect(payload.host == offer.host)
        #expect(payload.port == offer.port)
        #expect(LoginOfferQR.cgImage(from: offer.uri) != nil)
        #expect(PairingExpiry.label(expiresAt: offer.expiresAt, now: iso("2026-08-16T22:07:00.000Z")) == "Expires in 3 minutes")
        #expect(PairingExpiry.label(expiresAt: offer.expiresAt, now: iso("2026-08-16T22:10:00.000Z")) == "Expired")
    }

    private func iso(_ raw: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)!
    }
}
