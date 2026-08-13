import Foundation

/// Stable USB identity used for list/attach/QEMU mapping (PAS-84).
///
/// Prefer `vendorId:productId:serial` when a serial is present. Fall back to
/// `bus:BBB.AAA` (unstable across replug) when the host exposes no serial.
public enum USBDeviceIdentity {
    public static let massStorageExclusionReason =
        "USB mass storage is excluded from passthrough. The host keeps storage-class "
            + "devices; attach a disk image or share the volume instead."

    public struct Ref: Equatable, Sendable {
        public let id: String
        public let vendorId: String
        public let productId: String
        public let serial: String?
        public let bus: Int?
        public let address: Int?
        public let unstable: Bool
    }

    public static func normalizeHexId(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("0x") {
            value.removeFirst(2)
        }
        let hex = value.filter(\.isHexDigit)
        guard !hex.isEmpty else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "0x" + hex.padLeft(toLength: 4, with: "0")
    }

    public static func normalizedSerial(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func make(
        vendorId: String,
        productId: String,
        serial: String?,
        bus: Int? = nil,
        address: Int? = nil,
    ) -> Ref {
        let vid = normalizeHexId(vendorId)
        let pid = normalizeHexId(productId)
        if let serial = normalizedSerial(serial) {
            return Ref(
                id: "\(vid):\(pid):\(encodeSerial(serial))",
                vendorId: vid,
                productId: pid,
                serial: serial,
                bus: bus,
                address: address,
                unstable: false,
            )
        }
        if let bus, let address {
            return Ref(
                id: busAddressId(bus: bus, address: address),
                vendorId: vid,
                productId: pid,
                serial: nil,
                bus: bus,
                address: address,
                unstable: true,
            )
        }
        return Ref(
            id: "\(vid):\(pid)",
            vendorId: vid,
            productId: pid,
            serial: nil,
            bus: bus,
            address: address,
            unstable: true,
        )
    }

    public static func busAddressId(bus: Int, address: Int) -> String {
        String(format: "bus:%03d.%03d", bus, address)
    }

    public static func parse(_ raw: String) -> Ref? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if id.hasPrefix("bus:") {
            let rest = id.dropFirst(4)
            let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, let bus = Int(parts[0]), let address = Int(parts[1]) else {
                return nil
            }
            return Ref(
                id: busAddressId(bus: bus, address: address),
                vendorId: "",
                productId: "",
                serial: nil,
                bus: bus,
                address: address,
                unstable: true,
            )
        }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let vid = normalizeHexId(parts[0])
        let pid = normalizeHexId(parts[1])
        if parts.count == 2 {
            return Ref(
                id: "\(vid):\(pid)",
                vendorId: vid,
                productId: pid,
                serial: nil,
                bus: nil,
                address: nil,
                unstable: true,
            )
        }
        let encodedSerial = parts.dropFirst(2).joined(separator: ":")
        guard let serial = normalizedSerial(decodeSerial(encodedSerial)) else { return nil }
        return make(vendorId: vid, productId: pid, serial: serial)
    }

    public static func encodeSerial(_ serial: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return serial.addingPercentEncoding(withAllowedCharacters: allowed) ?? serial
    }

    public static func decodeSerial(_ encoded: String) -> String {
        encoded.removingPercentEncoding ?? encoded
    }
}

extension String {
    fileprivate func padLeft(toLength length: Int, with pad: Character) -> String {
        if count >= length { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}
