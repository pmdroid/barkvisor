import Foundation

/// Removes every local record that makes a peer part of this Home.
///
/// This intentionally does not contact the peer. The directory governs both
/// Home listing and member proxy eligibility, while the pin store governs the
/// pairing trust relationship. Validate both files before changing either so
/// a corrupt local file cannot leave a half-removed member behind.
public enum HomeDeviceMembership {
    private static let lock = NSLock()

    public static func remove(
        hostId: String,
        localHostId: String,
        dataDir: URL,
        devices: DeviceRegistry? = nil,
        pins: PeerPinStore? = nil,
    ) throws {
        let target = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw BarkVisorError.badRequest("Device id is required")
        }
        guard target != localHostId else {
            throw BarkVisorError.forbidden("This Device cannot remove itself from the Home")
        }

        let directory = devices ?? DeviceRegistry(dataDir: dataDir)
        let pinStore = pins ?? PeerPinStore(dataDir: dataDir)
        lock.lock()
        defer { lock.unlock() }

        // Preflight makes the normal removal path all-or-nothing even if an
        // on-disk store is corrupt. Both removals are idempotent.
        _ = try directory.load()
        _ = try pinStore.load()
        try pinStore.unpin(hostId: target)
        try directory.remove(hostId: target)
    }
}
