import XCTest
@testable import BarkVisorCore

final class JSONColumnCodingTests: XCTestCase {
    // MARK: - decodeArray

    func testDecodeArrayFromValidJSON() {
        let json = "[\"a\",\"b\",\"c\"]"
        let result = JSONColumnCoding.decodeArray(String.self, from: json)
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testDecodeArrayFromNil() {
        let result = JSONColumnCoding.decodeArray(String.self, from: nil)
        XCTAssertNil(result)
    }

    func testDecodeArrayFromInvalidJSON() {
        let result = JSONColumnCoding.decodeArray(String.self, from: "not json")
        XCTAssertNil(result)
    }

    func testDecodeArrayFromEmptyString() {
        let result = JSONColumnCoding.decodeArray(String.self, from: "")
        XCTAssertNil(result)
    }

    func testDecodeArrayOfInts() {
        let json = "[1,2,3]"
        let result = JSONColumnCoding.decodeArray(Int.self, from: json)
        XCTAssertEqual(result, [1, 2, 3])
    }

    // MARK: - decode single value

    func testDecodeSingleValue() {
        let json = "{\"name\":\"test\",\"loginTime\":1234.5}"
        let result = JSONColumnCoding.decode(GuestUserDTO.self, from: json)
        XCTAssertEqual(result?.name, "test")
        XCTAssertEqual(result?.loginTime, 1_234.5)
    }

    func testDecodeSingleValueFromNil() {
        let result = JSONColumnCoding.decode(GuestUserDTO.self, from: nil)
        XCTAssertNil(result)
    }

    func testDecodeSingleValueFromInvalidJSON() {
        let result = JSONColumnCoding.decode(GuestUserDTO.self, from: "bad")
        XCTAssertNil(result)
    }

    // MARK: - encode

    func testEncodeValue() throws {
        let users = [GuestUserDTO(name: "alice", loginTime: nil)]
        let json = JSONColumnCoding.encode(users)
        XCTAssertNotNil(json)
        XCTAssertTrue(try XCTUnwrap(json?.contains("alice")))
    }

    func testEncodeNil() {
        let result = JSONColumnCoding.encode(nil as [String]?)
        XCTAssertNil(result)
    }

    // MARK: - Round trip

    func testRoundTrip() {
        let original = [
            PortForwardRule(protocol: "tcp", hostPort: 2_222, guestPort: 22),
            PortForwardRule(protocol: "udp", hostPort: 5_353, guestPort: 53),
        ]
        let encoded = JSONColumnCoding.encode(original)
        XCTAssertNotNil(encoded)
        let decoded = JSONColumnCoding.decodeArray(PortForwardRule.self, from: encoded)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?[0].hostPort, 2_222)
        XCTAssertEqual(decoded?[1].guestPort, 53)
    }
}
