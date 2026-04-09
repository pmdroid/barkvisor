import Foundation

/// Validate a VM name: must be 1-128 characters, alphanumeric, hyphens, underscores, dots, spaces.
public func validateVMName(_ name: String) throws {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count <= 128 else {
        throw BarkVisorError.badRequest("VM name must be 1-128 characters")
    }
    guard trimmed.allSatisfy({
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == " "
    })
    else {
        throw BarkVisorError.badRequest(
            "VM name may only contain letters, numbers, hyphens, underscores, dots, and spaces",
        )
    }
}

/// Validate a bridge interface name: alphanumeric only (e.g. "en0", "bridge0").
public func validateBridgeName(_ name: String) throws {
    guard name.allSatisfy({ $0.isLetter || $0.isNumber }) else {
        throw BarkVisorError.badRequest("Bridge interface name must be alphanumeric (got '\(name)')")
    }
    guard name.count <= 15 else {
        throw BarkVisorError.badRequest("Bridge interface name too long (max 15 chars)")
    }
}

/// Validate a DNS server is a valid IPv4 address.
public func validateDNS(_ dns: String) throws {
    let parts = dns.split(separator: ".")
    guard parts.count == 4,
          parts.allSatisfy({ part in
              guard let n = UInt16(part), n <= 255 else { return false }
              return part == String(n)
          })
    else {
        throw BarkVisorError.badRequest("DNS server must be a valid IPv4 address (got '\(dns)')")
    }
}

/// Validate a MAC address: XX:XX:XX:XX:XX:XX hex format.
public func validateMAC(_ mac: String) throws {
    let parts = mac.split(separator: ":")
    guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
        throw BarkVisorError.badRequest("MAC address must be in XX:XX:XX:XX:XX:XX format")
    }
}
