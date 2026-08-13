import Foundation

/// Canonical guest type profile keyed by the **persisted** `vm.vmType` ID.
///
/// Stable IDs (do not rename without a data migration):
/// - `linux-arm64`, `windows-arm64`, `linux-amd64`, `linux-x86_64`
public struct GuestProfile: Sendable, Equatable, Codable, Hashable {
    /// Persisted VM type string stored in the database / API.
    public let id: String
    /// Host/API arch label (`arm64` / `x86_64`).
    public let arch: String
    /// QEMU binary arch (`aarch64` / `x86_64`) for `qemu-system-*`.
    public let qemuArch: String
    /// QEMU `-machine` type.
    public let machine: String
    /// OS family (`linux` / `windows`).
    public let osFamily: String
    /// Whether TPM is recommended/default for this guest.
    public let defaultTPMEnabled: Bool
    /// Firmware selection key for QEMUBuilder.
    public let firmware: Firmware

    public enum Firmware: String, Sendable, Codable, Hashable {
        case edk2ARM64
        case aavmfSecureBoot
        case edk2X86
    }

    public var qemuBinaryName: String {
        "qemu-system-\(qemuArch)"
    }

    public var isWindows: Bool {
        osFamily == "windows"
    }

    public var isX86: Bool {
        arch == "x86_64"
    }

    public var isARM64: Bool {
        arch == "arm64"
    }
}

/// Table of supported guest profiles. Single source for validation, QEMU, and API.
public enum GuestProfiles {
    public static let all: [GuestProfile] = [
        GuestProfile(
            id: "linux-arm64",
            arch: "arm64",
            qemuArch: "aarch64",
            machine: "virt",
            osFamily: "linux",
            defaultTPMEnabled: false,
            firmware: .edk2ARM64,
        ),
        GuestProfile(
            id: "windows-arm64",
            arch: "arm64",
            qemuArch: "aarch64",
            machine: "virt",
            osFamily: "windows",
            defaultTPMEnabled: true,
            firmware: .aavmfSecureBoot,
        ),
        GuestProfile(
            id: "linux-amd64",
            arch: "x86_64",
            qemuArch: "x86_64",
            machine: "q35",
            osFamily: "linux",
            defaultTPMEnabled: false,
            firmware: .edk2X86,
        ),
        // Alias of linux-amd64 arch — kept as a stable persisted ID.
        GuestProfile(
            id: "linux-x86_64",
            arch: "x86_64",
            qemuArch: "x86_64",
            machine: "q35",
            osFamily: "linux",
            defaultTPMEnabled: false,
            firmware: .edk2X86,
        ),
    ]

    public static let byID: [String: GuestProfile] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) },
    )

    public static var supportedIDs: [String] {
        all.map(\.id)
    }

    /// Resolve a profile or throw `unknownVMType`.
    public static func require(_ id: String) throws -> GuestProfile {
        guard let profile = byID[id] else {
            throw BarkVisorError.unknownVMType(id)
        }
        return profile
    }

    /// Optional lookup (no throw).
    public static func profile(for id: String) -> GuestProfile? {
        byID[id]
    }

    /// Map host/image arch (`arm64` / `x86_64` / aliases) to default Linux guest ID.
    public static func defaultLinuxID(forImageArch arch: String) -> String {
        switch PlatformCapabilities.normalizedArch(arch) {
        case "arm64":
            return "linux-arm64"
        case "x86_64":
            return "linux-amd64"
        default:
            return "linux-\(arch)"
        }
    }

    /// Guest profiles that can run natively on the given host arch (PAS-48).
    public static func profilesCompatible(withHostArch hostArch: String) -> [GuestProfile] {
        let host = PlatformCapabilities.normalizedArch(hostArch)
        return all.filter { PlatformCapabilities.normalizedArch($0.arch) == host }
    }

    /// Default Windows guest ID for a host/image arch, if supported.
    /// Only `windows-arm64` exists today; x86_64 Windows is not a guest profile yet.
    public static func defaultWindowsID(forImageArch arch: String) -> String? {
        switch PlatformCapabilities.normalizedArch(arch) {
        case "arm64":
            return "windows-arm64"
        default:
            return nil
        }
    }

    /// Default persisted guest ID when the client omits `vmType` / `guestType`.
    ///
    /// `osFamily` is `linux` (default) or `windows`. Arch defaults to the host.
    public static func defaultID(
        osFamily: String?,
        imageArch: String = PlatformCapabilities.hostArch,
    ) throws -> String {
        let family = (osFamily ?? "linux")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if family == "windows" {
            guard let id = defaultWindowsID(forImageArch: imageArch) else {
                let arch = PlatformCapabilities.normalizedArch(imageArch)
                throw BarkVisorError.badRequest("No Windows guest type for arch \(arch)")
            }
            return id
        }
        if !family.isEmpty, family != "linux" {
            throw BarkVisorError.badRequest("osFamily must be linux or windows")
        }
        return defaultLinuxID(forImageArch: imageArch)
    }
}
