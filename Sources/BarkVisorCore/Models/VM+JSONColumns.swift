import Foundation

/// Typed accessors for VM JSON TEXT columns (no schema change).
///
/// **Error policy:** corrupt/missing JSON → log + empty array (or nil for optional API fields).
/// Prefer continuing VM operations over throwing on bad stored data.
extension VM {
    // MARK: - Read (log + empty on error)

    /// ISO image IDs; falls back to legacy `isoId` when `isoIds` is empty/nil.
    public var decodedISOIds: [String] {
        let fromJSON = JSONColumnCoding.decodeArrayOrEmpty(
            String.self, from: isoIds, column: "isoIds",
        )
        if !fromJSON.isEmpty { return fromJSON }
        if let legacyId = isoId { return [legacyId] }
        return []
    }

    public var decodedAdditionalDiskIds: [String] {
        JSONColumnCoding.decodeArrayOrEmpty(
            String.self, from: additionalDiskIds, column: "additionalDiskIds",
        )
    }

    public var decodedSharedPaths: [String] {
        JSONColumnCoding.decodeArrayOrEmpty(
            String.self, from: sharedPaths, column: "sharedPaths",
        )
    }

    public var decodedPortForwards: [PortForwardRule] {
        JSONColumnCoding.decodeArrayOrEmpty(
            PortForwardRule.self, from: portForwards, column: "portForwards",
        )
    }

    public var decodedUSBDevices: [USBPassthroughDevice] {
        JSONColumnCoding.decodeArrayOrEmpty(
            USBPassthroughDevice.self, from: usbDevices, column: "usbDevices",
        )
    }

    // MARK: - Write (empty → nil column)

    public mutating func setISOIds(_ ids: [String]?) {
        isoIds = JSONColumnCoding.encodeArrayOrNil(ids)
        // Clear legacy single-ISO column when using the array form.
        if ids != nil {
            isoId = nil
        }
    }

    public mutating func setAdditionalDiskIds(_ ids: [String]?) {
        additionalDiskIds = JSONColumnCoding.encodeArrayOrNil(ids)
    }

    public mutating func setSharedPaths(_ paths: [String]?) {
        sharedPaths = JSONColumnCoding.encodeArrayOrNil(paths)
    }

    public mutating func setPortForwards(_ rules: [PortForwardRule]?) {
        portForwards = JSONColumnCoding.encodeArrayOrNil(rules)
    }

    public mutating func setUSBDevices(_ devices: [USBPassthroughDevice]?) {
        usbDevices = JSONColumnCoding.encodeArrayOrNil(devices)
    }
}
