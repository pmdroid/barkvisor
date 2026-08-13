import Crypto
import Foundation

/// Short pairing code (PAS-45). Human-typeable, single-use, short-lived.
///
/// Alphabet excludes ambiguous characters (`0`, `1`, `I`, `L`, `O`, `U`).
/// Display form is `XXXX-XXXX`.
public enum PairingCode {
    public static let length = 8
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")

    public static func generate(bytes: [UInt8] = PlatformRandom.secureBytes(count: length)) -> String {
        let source = bytes.count >= length ? bytes : PlatformRandom.secureBytes(count: length)
        var chars: [Character] = []
        chars.reserveCapacity(length)
        for i in 0 ..< length {
            chars.append(alphabet[Int(source[i]) % alphabet.count])
        }
        return display(String(chars))
    }

    public static func display(_ raw: String) -> String {
        let normalized = normalize(raw)
        guard normalized.count == length else { return raw }
        let mid = normalized.index(normalized.startIndex, offsetBy: 4)
        return "\(normalized[..<mid])-\(normalized[mid...])"
    }

    public static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func isValid(_ raw: String) -> Bool {
        let normalized = normalize(raw)
        guard normalized.count == length else { return false }
        return normalized.allSatisfy { alphabet.contains($0) }
    }

    public static func hash(_ raw: String) -> String {
        let normalized = normalize(raw)
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func hashesEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var acc: UInt8 = 0
        for i in 0 ..< a.count {
            acc |= a[i] ^ b[i]
        }
        return acc == 0
    }
}
