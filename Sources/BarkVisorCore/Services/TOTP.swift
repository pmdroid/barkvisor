#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

/// RFC 4648 Base32 (no padding) for TOTP secrets.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ data: Data) -> String {
        var result = ""
        var buffer: UInt = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | UInt(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1F)
                result.append(alphabet[index])
            }
        }
        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            result.append(alphabet[index])
        }
        return result
    }

    public static func decode(_ string: String) -> Data? {
        let cleaned = string.uppercased().filter { $0 != "=" && !$0.isWhitespace }
        guard !cleaned.isEmpty else { return nil }
        var buffer: UInt = 0
        var bitsLeft = 0
        var out = Data()
        for ch in cleaned {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt(idx)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                out.append(UInt8((buffer >> bitsLeft) & 0xFF))
            }
        }
        return out
    }
}

/// RFC 6238 TOTP (HMAC-SHA1, 30s step, 6 digits by default).
public enum TOTP {
    public static let digits = 6
    public static let period: TimeInterval = 30
    public static let window = 1
    public static let issuer = "BarkVisor"

    public static func generateSecret(bytes: [UInt8] = PlatformRandom.secureBytes(count: 20)) -> String {
        Base32.encode(Data(bytes))
    }

    public static func generate(secret: Data, at date: Date, digits: Int = 6) -> String {
        let counter = UInt64(date.timeIntervalSince1970 / period)
        return generate(secret: secret, counter: counter, digits: digits)
    }

    public static func generate(secret: Data, counter: UInt64, digits: Int = 6) -> String {
        var be = counter.bigEndian
        let counterData = withUnsafeBytes(of: &be) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let hash = Array(mac)
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let b0 = UInt32(hash[offset] & 0x7F) << 24
        let b1 = UInt32(hash[offset + 1]) << 16
        let b2 = UInt32(hash[offset + 2]) << 8
        let b3 = UInt32(hash[offset + 3])
        let binary = b0 | b1 | b2 | b3
        let modulus = UInt32(pow10(digits))
        let otp = binary % modulus
        return String(format: "%0\(digits)d", otp)
    }

    /// Returns the matched counter when `code` is valid in the ±window and newer than `lastUsedCounter`.
    public static func verify(
        code: String,
        secret: Data,
        at date: Date,
        lastUsedCounter: UInt64? = nil,
        digits: Int = 6,
        window: Int = 1,
    ) -> UInt64? {
        let normalized = code.filter(\.isNumber)
        guard normalized.count == digits else { return nil }
        let center = Int64(date.timeIntervalSince1970 / period)
        for delta in -window ... window {
            let raw = center + Int64(delta)
            guard raw >= 0 else { continue }
            let counter = UInt64(raw)
            if let last = lastUsedCounter, counter <= last { continue }
            let expected = generate(secret: secret, counter: counter, digits: digits)
            if constantTimeEquals(expected, normalized) {
                return counter
            }
        }
        return nil
    }

    public static func otpauthURL(secret: String, account: String, issuer: String = issuer) -> String {
        let label = "\(issuer):\(account)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "\(issuer):\(account)"
        let encodedIssuer = issuer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issuer
        return
            "otpauth://totp/\(label)?secret=\(secret)&issuer=\(encodedIssuer)&algorithm=SHA1&digits=\(digits)&period=\(Int(period))"
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< left.count {
            diff |= left[i] ^ right[i]
        }
        return diff == 0
    }

    private static func pow10(_ digits: Int) -> UInt32 {
        var n: UInt32 = 1
        for _ in 0 ..< digits {
            n *= 10
        }
        return n
    }
}
