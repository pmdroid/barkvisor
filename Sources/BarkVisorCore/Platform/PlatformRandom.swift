import Foundation

#if os(macOS)
import Security
#endif

/// Secure random bytes for secrets and salts.
public enum PlatformRandom {
    /// Fill `count` cryptographically secure random bytes.
    public static func secureBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        #if os(macOS)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes
        }
        // Fall through to SystemRandomNumberGenerator if SecRandom fails unexpectedly.
        #endif
        var rng = SystemRandomNumberGenerator()
        for i in 0 ..< count {
            bytes[i] = UInt8.random(in: 0 ... 255, using: &rng)
        }
        return bytes
    }

    /// Base64-encoded secure random string (default 32 raw bytes).
    public static func secureBase64(byteCount: Int = 32) -> String {
        Data(secureBytes(count: byteCount)).base64EncodedString()
    }
}
