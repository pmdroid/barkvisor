import Foundation

public enum LocalManagementFraming {
    public static func encode(_ request: LocalManagementRequest) throws -> Data {
        try pack(JSONEncoder().encode(request))
    }

    public static func encode(_ response: LocalManagementResponse) throws -> Data {
        try pack(JSONEncoder().encode(response))
    }

    public static func decodeRequest(_ payload: Data) throws -> LocalManagementRequest {
        do {
            return try JSONDecoder().decode(LocalManagementRequest.self, from: payload)
        } catch {
            throw LocalManagementError.malformed
        }
    }

    public static func decodeResponse(_ payload: Data) throws -> LocalManagementResponse {
        do {
            return try JSONDecoder().decode(LocalManagementResponse.self, from: payload)
        } catch {
            throw LocalManagementError.malformed
        }
    }

    public static func payloadLength(prefix: Data) throws -> Int {
        guard prefix.count == 4 else { throw LocalManagementError.malformed }
        let value = (UInt32(prefix[prefix.startIndex]) << 24)
            | (UInt32(prefix[prefix.startIndex + 1]) << 16)
            | (UInt32(prefix[prefix.startIndex + 2]) << 8)
            | UInt32(prefix[prefix.startIndex + 3])
        if value == 0 || value > UInt32(LocalManagementLimits.maxPayloadBytes) {
            throw LocalManagementError.payloadTooLarge
        }
        return Int(value)
    }

    private static func pack(_ payload: Data) throws -> Data {
        if payload.isEmpty || payload.count > LocalManagementLimits.maxPayloadBytes {
            throw LocalManagementError.payloadTooLarge
        }
        var framed = Data(capacity: 4 + payload.count)
        let count = UInt32(payload.count)
        framed.append(UInt8((count >> 24) & 0xFF))
        framed.append(UInt8((count >> 16) & 0xFF))
        framed.append(UInt8((count >> 8) & 0xFF))
        framed.append(UInt8(count & 0xFF))
        framed.append(payload)
        return framed
    }
}
