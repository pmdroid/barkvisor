import Foundation

/// Removes every local record that makes a peer part of this Home.
///
/// This intentionally does not contact the peer. The directory governs both
/// Home listing and member proxy eligibility, while the pin store governs the
/// pairing trust relationship. Validate both files before changing either so
/// a corrupt local file cannot leave a half-removed member behind.
public enum HomeDeviceMembership {
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

        try HomeMembershipAuthority(dataDir: dataDir).removeMember(
            hostId: target,
            localHostId: localHostId,
            devices: devices,
            pins: pins,
        )
    }
}
