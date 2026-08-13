import Foundation

/// Effective QEMU launch backend for one workload (PAS-73).
///
/// Projected from the same guest profile + accelerator `QEMUBuilder.launchConfig`
/// uses, so list/detail show what would actually be launched — not host defaults
/// alone (qemu binary and guest arch follow `vmType`).
public struct VMRuntimeBackend: Codable, Equatable, Sendable {
    /// QEMU `-accel` value (`hvf` / `kvm` / `tcg`).
    public var accelerator: String
    /// Guest arch API label (`arm64` / `x86_64`).
    public var guestArch: String
    /// QEMU binary name (`qemu-system-aarch64` / `qemu-system-x86_64`).
    public var qemuBinary: String
    /// True when TCG or guest arch ≠ host arch.
    public var emulated: Bool
    /// Performance warning when `emulated`; nil for native hardware accel.
    public var warning: String?

    public init(
        accelerator: String,
        guestArch: String,
        qemuBinary: String,
        emulated: Bool,
        warning: String? = nil,
    ) {
        self.accelerator = accelerator
        self.guestArch = guestArch
        self.qemuBinary = qemuBinary
        self.emulated = emulated
        self.warning = warning
    }
}
