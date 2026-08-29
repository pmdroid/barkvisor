import GRDB

/// #385: persist guest LAN addressing (DHCP default, optional static via cloud-init).
/// Host `br0` addressing stays on #378.
public struct M017_GuestAddressing: DatabaseMigration {
    public static let identifier = "M017_GuestAddressing"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "guestAddressingJson", .text)
        }
    }
}
