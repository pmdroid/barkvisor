import Foundation

/// Minimal native create: name + ready Library image + server defaults. No hardware wizard.
enum CreateWorkload {
    static let linuxCPUCount = 2
    static let linuxMemoryMB = 1_024
    static let linuxDiskGB = 10
    static let windowsCPUCount = 4
    static let windowsMemoryMB = 4_096
    static let windowsDiskGB = 64

    static let emptyLibraryCopy =
        "Download a catalog image into the Library, then create a Workload."

    static let webEditCopy = "Edit hardware, disks, networks, USB in the web UI."

    static func ready(_ images: [LibraryImage]) -> [LibraryImage] {
        images.filter(\.isReady).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func hasReadyImage(_ images: [LibraryImage]) -> Bool {
        images.contains(where: \.isReady)
    }

    static func canSubmit(name: String, image: LibraryImage?, loadingImages: Bool = false) -> Bool {
        guard !loadingImages, let image, image.isReady else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sorted reachable Device ids. Home re-scans Library readiness when this changes.
    static func reachableDeviceKey(_ devices: [HomeDeviceHealthSnapshot]) -> String {
        devices.filter(\.isReachable).map(\.hostId).sorted().joined(separator: "\n")
    }

    /// Drop a cancelled or superseded GET /images so Create cannot POST another Device's image id.
    static func shouldApplyLibraryLoad(loadID: Int, currentID: Int, cancelled: Bool) -> Bool {
        !cancelled && loadID == currentID
    }

    static func osFamily(for image: LibraryImage) -> String {
        osFamily(fromName: image.name)
    }

    /// Web wizard picks Linux vs Windows explicitly. Native infers from the Library name,
    /// including official installer names like `Win11_English_x64.iso` (no "windows" substring).
    static func osFamily(fromName raw: String) -> String {
        isWindowsImageName(raw) ? "windows" : "linux"
    }

    static func isWindowsImageName(_ raw: String) -> Bool {
        let haystack = raw.lowercased()
        if haystack.contains("windows") { return true }
        // Win11_English_x64.iso, Win10_22H2, Win8.1, Win7, WinXP. Not virtio-win or *x64* Linux ISOs.
        let pattern = #"(?:^|[^a-z0-9])win(?:dows)?[\s._-]*(?:11|10|8(?:\.1)?|7|xp|vista|server|nt|me|9x)"#
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    static func normalizedArch(_ raw: String) -> String {
        switch raw.lowercased() {
        case "arm64", "aarch64": "arm64"
        case "x86_64", "amd64", "x86-64": "x86_64"
        default: raw
        }
    }

    /// Guest type from the image arch (and Windows vs Linux), not this console's CPU.
    static func guestType(osFamily: String, arch: String) -> String {
        let imageArch = normalizedArch(arch)
        if osFamily.lowercased() == "windows" {
            return imageArch == "x86_64" ? "windows-amd64" : "windows-arm64"
        }
        return imageArch == "x86_64" ? "linux-amd64" : "linux-arm64"
    }

    static func cpuCount(osFamily: String, hostCPUCount: Int?) -> Int {
        let preferred = osFamily == "windows" ? windowsCPUCount : linuxCPUCount
        guard let hostCPUCount, hostCPUCount >= 1 else { return preferred }
        return min(preferred, hostCPUCount)
    }

    static func memoryMB(osFamily: String) -> Int {
        osFamily == "windows" ? windowsMemoryMB : linuxMemoryMB
    }

    static func diskSizeGB(osFamily: String) -> Int {
        osFamily == "windows" ? windowsDiskGB : linuxDiskGB
    }

    static func isISO(_ image: LibraryImage) -> Bool {
        image.imageType.lowercased() == "iso"
    }

    enum DraftError: Error, Equatable, LocalizedError {
        case emptyName
        case imageNotReady

        var errorDescription: String? {
            switch self {
            case .emptyName: "Name is required"
            case .imageNotReady: "Pick a ready Library image"
            }
        }
    }

    /// Same keys as the web wizard `CreateVMRequest`. `networkId` is omitted (implicit NAT).
    struct Body: Equatable, Encodable {
        var name: String
        var osFamily: String
        var vmType: String
        var cpuCount: Int
        var memoryMB: Int
        var diskSizeGB: Int
        var isoId: String?
        var cloudImageId: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(osFamily, forKey: .osFamily)
            try container.encode(vmType, forKey: .vmType)
            try container.encode(cpuCount, forKey: .cpuCount)
            try container.encode(memoryMB, forKey: .memoryMB)
            try container.encode(diskSizeGB, forKey: .diskSizeGB)
            try container.encodeIfPresent(isoId, forKey: .isoId)
            try container.encodeIfPresent(cloudImageId, forKey: .cloudImageId)
        }

        private enum CodingKeys: String, CodingKey {
            case name, osFamily, vmType, cpuCount, memoryMB, diskSizeGB, isoId, cloudImageId
        }
    }

    static func body(name: String, image: LibraryImage, hostCPUCount: Int?) throws -> Body {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftError.emptyName }
        guard image.isReady else { throw DraftError.imageNotReady }
        let family = osFamily(for: image)
        let iso = isISO(image)
        return Body(
            name: trimmed,
            osFamily: family,
            vmType: guestType(osFamily: family, arch: image.arch),
            cpuCount: cpuCount(osFamily: family, hostCPUCount: hostCPUCount),
            memoryMB: memoryMB(osFamily: family),
            diskSizeGB: diskSizeGB(osFamily: family),
            isoId: iso ? image.id : nil,
            cloudImageId: iso ? nil : image.id,
        )
    }
}

extension LibraryImage {
    var isReady: Bool {
        status.lowercased() == "ready"
    }
}

struct CreateWorkloadAccepted: Decodable {
    var taskID: String
    var vm: Workload
}
