import Foundation
import Testing
@testable import BarkVisorCore

@Suite struct JSONColumnCodingTests {
    // MARK: - decodeArray

    @Test func decodeArrayFromValidJSON() {
        let json = "[\"a\",\"b\",\"c\"]"
        let result = JSONColumnCoding.decodeArray(String.self, from: json)
        #expect(result == ["a", "b", "c"])
    }

    @Test func decodeArrayFromNil() {
        let result = JSONColumnCoding.decodeArray(String.self, from: nil)
        #expect(result == nil)
    }

    @Test func decodeArrayFromInvalidJSON() {
        let result = JSONColumnCoding.decodeArray(String.self, from: "not json")
        #expect(result == nil)
    }

    @Test func decodeArrayFromEmptyString() {
        let result = JSONColumnCoding.decodeArray(String.self, from: "")
        #expect(result == nil)
    }

    @Test func decodeArrayOfInts() {
        let json = "[1,2,3]"
        let result = JSONColumnCoding.decodeArray(Int.self, from: json)
        #expect(result == [1, 2, 3])
    }

    // MARK: - decode single value

    @Test func decodeSingleValue() {
        let json = "{\"name\":\"test\",\"loginTime\":1234.5}"
        let result = JSONColumnCoding.decode(GuestUserDTO.self, from: json)
        #expect(result?.name == "test")
        #expect(result?.loginTime == 1_234.5)
    }

    @Test func decodeSingleValueFromNil() {
        let result = JSONColumnCoding.decode(GuestUserDTO.self, from: nil)
        #expect(result == nil)
    }

    @Test func decodeSingleValueFromInvalidJSON() {
        let result = JSONColumnCoding.decode(GuestUserDTO.self, from: "bad")
        #expect(result == nil)
    }

    // MARK: - encode

    @Test func encodeValue() throws {
        let users = [GuestUserDTO(name: "alice", loginTime: nil)]
        let json = JSONColumnCoding.encode(users)
        #expect(json != nil)
        let unwrapped = try #require(json)
        #expect(unwrapped.contains("alice"))
    }

    @Test func encodeNil() {
        let result = JSONColumnCoding.encode(nil as [String]?)
        #expect(result == nil)
    }

    // MARK: - Round trip

    @Test func roundTrip() {
        let original = [
            PortForwardRule(protocol: "tcp", hostPort: 2_222, guestPort: 22),
            PortForwardRule(protocol: "udp", hostPort: 5_353, guestPort: 53),
        ]
        let encoded = JSONColumnCoding.encode(original)
        #expect(encoded != nil)
        let decoded = JSONColumnCoding.decodeArray(PortForwardRule.self, from: encoded)
        #expect(decoded?.count == 2)
        #expect(decoded?[0].hostPort == 2_222)
        #expect(decoded?[1].guestPort == 53)
    }
}
