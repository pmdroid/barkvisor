import Foundation

/// MAC address utilities.
public enum MACAddress {
    /// Generate a random QEMU MAC address with the 52:54:00 prefix.
    public static func generateQemu() -> String {
        let bytes = (0 ..< 3).map { _ in UInt8.random(in: 0 ... 255) }
        return String(format: "52:54:00:%02x:%02x:%02x", bytes[0], bytes[1], bytes[2])
    }
}
