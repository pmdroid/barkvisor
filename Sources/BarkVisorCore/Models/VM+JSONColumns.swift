import Foundation

/// Typed accessors for VM JSON TEXT columns (no schema change).
///
/// **Error policy:** corrupt/missing JSON → log + empty array (or nil for optional API fields).
/// Prefer continuing VM operations over throwing on bad stored data.
extension VM {
    // MARK: - Read (log + empty on error)

    /// ISO image IDs stored in `isoIds` (legacy `isoId` column dropped in M002).
    public var decodedISOIds: [String] {
        JSONColumnCoding.decodeArrayOrEmpty(
            String.self, from: isoIds, column: "isoIds",
        )
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

    public var decodedOverrides: WorkloadOverrides? {
        let decoded = JSONColumnCoding.decode(WorkloadOverrides.self, from: overridesJson)
        guard let decoded, !decoded.isEmpty else { return nil }
        return decoded
    }

    public var decodedHealth: WorkloadHealthSpec? {
        JSONColumnCoding.decode(WorkloadHealthSpec.self, from: healthJson)
    }

    public var decodedSession: CodingAgentSessionState? {
        JSONColumnCoding.decode(CodingAgentSessionState.self, from: sessionJson)
    }

    // MARK: - Write (empty → nil column)

    public mutating func setISOIds(_ ids: [String]?) {
        isoIds = JSONColumnCoding.encodeArrayOrNil(ids)
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

    public mutating func setOverrides(_ overrides: WorkloadOverrides?) {
        if let overrides, !overrides.isEmpty {
            overridesJson = JSONColumnCoding.encode(overrides)
        } else {
            overridesJson = nil
        }
    }

    public mutating func setHealth(_ health: WorkloadHealthSpec?) {
        if let health, health.hasProbes {
            healthJson = JSONColumnCoding.encode(health)
        } else {
            healthJson = nil
        }
    }

    public mutating func setSession(_ session: CodingAgentSessionState?) {
        sessionJson = JSONColumnCoding.encode(session)
    }
}
