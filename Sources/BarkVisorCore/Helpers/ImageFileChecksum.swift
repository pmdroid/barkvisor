#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

/// Hex digest of a stored Library file. Used after download/upload so a later
/// depot verify can compare bytes without CAS (PAS-36).
public enum ImageFileChecksum {
    public static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func sha512Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA512()
        while true {
            let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Compare a catalog hash to the file by streaming. Never loads the whole file.
    public static func verify(
        ofFile url: URL,
        expected: ExpectedChecksum,
        knownSha256: String? = nil,
    ) throws {
        let computed: String
        let algorithm: String
        let want: String
        switch expected {
        case let .sha256(hash):
            computed = try knownSha256 ?? sha256Hex(ofFile: url)
            algorithm = "SHA256"
            want = hash.lowercased()
        case let .sha512(hash):
            computed = try sha512Hex(ofFile: url)
            algorithm = "SHA512"
            want = hash.lowercased()
        }
        guard computed.lowercased() == want else {
            throw BarkVisorError.downloadFailed(
                "\(algorithm) mismatch: expected \(want), got \(computed.lowercased())",
            )
        }
    }
}
