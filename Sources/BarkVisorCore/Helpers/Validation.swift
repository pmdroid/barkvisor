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

/// Validate a host network interface / bridge name.
/// Linux IFNAMSIZ is 16 including NUL, so max 15 bytes. Allow letters, digits,
/// `.`, `_`, `-` so real names like `br-lan`, `br0`, Docker `br-<hash>`, and
/// `ovs-br0` pass; reject whitespace, path separators, and shell metacharacters.
public func validateBridgeName(_ name: String) throws {
    guard !name.isEmpty else {
        throw BarkVisorError.badRequest("Bridge interface name must not be empty")
    }
    // Kernel IFNAMSIZ-1 (bytes). Names here are ASCII; count == utf8.count.
    guard name.utf8.count <= 15 else {
        throw BarkVisorError.badRequest(
            "Bridge interface name too long (max 15 characters, IFNAMSIZ-1; got '\(name)')",
        )
    }
    guard name.allSatisfy({ ch in
        ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-"
    })
    else {
        throw BarkVisorError.badRequest(
            "Bridge interface name may only contain letters, numbers, '.', '_', and '-' (got '\(name)')",
        )
    }
}

/// Validate a DNS server is a valid IPv4 address.
public func validateDNS(_ dns: String) throws {
    try validateIPv4(dns, label: "DNS server")
}

/// Validate a dotted-quad IPv4 address (no leading zeros).
public func validateIPv4(_ ip: String, label: String = "IPv4 address") throws {
    let parts = ip.split(separator: ".")
    guard parts.count == 4,
          parts.allSatisfy({ part in
              guard let n = UInt16(part), n <= 255 else { return false }
              return part == String(n)
          })
    else {
        throw BarkVisorError.badRequest("\(label) must be a valid IPv4 address (got '\(ip)')")
    }
}

/// Validate a MAC address: XX:XX:XX:XX:XX:XX hex format.
public func validateMAC(_ mac: String) throws {
    let parts = mac.split(separator: ":")
    guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
        throw BarkVisorError.badRequest("MAC address must be in XX:XX:XX:XX:XX:XX format")
    }
}
