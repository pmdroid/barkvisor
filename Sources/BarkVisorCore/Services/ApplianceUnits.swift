import Foundation

public enum ApplianceUnits {
    public static let supportedSchema = 1
    public static let daemon = "barkvisor-daemon"
    public static let server = "barkvisor-server"

    public static func allowsDowngrade(onDiskSchema: Int?) -> Bool {
        guard let onDiskSchema else { return true }
        return onDiskSchema <= supportedSchema
    }

    public static var doctorLine: String {
        "units=\(daemon),\(server)"
    }
}
