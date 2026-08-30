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

    static let agentGrantCopy = "WAN yes, house no."
    static let houseGrantCopy = "House: LAN and USB allowed."

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

    /// Once `deviceID` is set, never fall back to another Device. That would pair
    /// that Device with Library images loaded for `deviceID`.
    static func resolvedDevice(
        deviceID: String,
        reachable: [HomeDeviceHealthSnapshot],
        selected: HomeDeviceHealthSnapshot?,
    ) -> HomeDeviceHealthSnapshot? {
        if !deviceID.isEmpty {
            return reachable.first { $0.hostId == deviceID }
        }
        return selected.flatMap { $0.isReachable ? $0 : nil }
            ?? reachable.first { $0.isSelf }
            ?? reachable.first
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
        case invalidOpenAIBaseURL
        case missingOpenAIAPIKey
        case invalidOpenAIAPIKey
        case staticAddressingNotBridged
        case staticAddressingNotCloudInit
        case invalidGuestIPv4
        case invalidGuestPrefixLength
        case invalidGuestGateway
        case invalidGuestNameserver

        var errorDescription: String? {
            switch self {
            case .emptyName: "Name is required"
            case .imageNotReady: "Pick a ready Library image"
            case .invalidOpenAIBaseURL: "OPENAI_BASE_URL must be an http(s) URL"
            case .missingOpenAIAPIKey: "OPENAI_API_KEY is required"
            case .invalidOpenAIAPIKey: "OPENAI_API_KEY is invalid"
            case .staticAddressingNotBridged:
                "Static IPv4 is only for bridged Workloads. NAT uses port forwards."
            case .staticAddressingNotCloudInit:
                "Static IPv4 needs a cloud-init image. Installer ISOs: set it in the guest or on the router."
            case .invalidGuestIPv4: "Enter a valid IPv4 address."
            case .invalidGuestPrefixLength: "Prefix length must be 1–32."
            case .invalidGuestGateway: "Enter a valid gateway IPv4."
            case .invalidGuestNameserver: "Each DNS server must be an IPv4 address."
            }
        }
    }

    /// Same keys as the web wizard `CreateVMRequest`. `networkId` is omitted for implicit NAT.
    struct Body: Equatable, Encodable {
        var name: String
        var osFamily: String
        var vmType: String
        var cpuCount: Int
        var memoryMB: Int
        var diskSizeGB: Int
        var isoId: String?
        var cloudImageId: String?
        var networkId: String?
        var workloadClass: String?
        var cloudInit: CloudInitPayload?
        var guestAddressing: GuestAddressingInfo?

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
            try container.encodeIfPresent(networkId, forKey: .networkId)
            try container.encodeIfPresent(workloadClass, forKey: .workloadClass)
            try container.encodeIfPresent(cloudInit, forKey: .cloudInit)
            try container.encodeIfPresent(guestAddressing, forKey: .guestAddressing)
        }

        private enum CodingKeys: String, CodingKey {
            case name, osFamily, vmType, cpuCount, memoryMB, diskSizeGB, isoId, cloudImageId, networkId, workloadClass,
                 cloudInit, guestAddressing
        }
    }

    struct CloudInitPayload: Equatable, Encodable {
        var userData: String?
    }

    static func body(
        name: String,
        image: LibraryImage,
        hostCPUCount: Int?,
        workloadClass: String? = nil,
        openaiBaseURL: String? = nil,
        openaiAPIKey: String? = nil,
        network: NetworkRecord? = nil,
        addressing: GuestAddressingDraft? = nil,
    ) throws -> Body {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftError.emptyName }
        guard image.isReady else { throw DraftError.imageNotReady }
        let family = osFamily(for: image)
        let iso = isISO(image)
        let guestAddressing = try addressing?.payload(
            bridged: network?.mode.lowercased() == GuestAddressingDraft.networkModeBridged,
            cloudInit: !iso,
        )
        let coding = CodingAgentImage.matches(name: image.name)
        let memory = coding ? max(memoryMB(osFamily: family), CodingAgentImage.defaultMemoryMB) : memoryMB(
            osFamily: family,
        )
        let disk = coding ? max(diskSizeGB(osFamily: family), CodingAgentImage.defaultDiskGB) : diskSizeGB(
            osFamily: family,
        )
        let klass: String?
        if coding {
            klass = workloadClass == "house" ? "house" : "agent"
        } else {
            klass = workloadClass == "agent" ? "agent" : nil
        }
        let cloudInit: CloudInitPayload?
        if coding, !iso {
            let url = try CodingAgentImage.normalizeOpenAIBaseURL(openaiBaseURL)
            let trimmedURL = openaiBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let byo = !trimmedURL.isEmpty && url != CodingAgentImage.homeOllamaGrantURL
            let apiKey = try CodingAgentImage.normalizeOpenAIAPIKey(openaiAPIKey, required: byo)
            cloudInit = CloudInitPayload(
                userData: CodingAgentImage.userData(
                    openaiBaseURL: url,
                    openaiAPIKey: apiKey,
                ),
            )
        } else {
            cloudInit = nil
        }
        return Body(
            name: trimmed,
            osFamily: family,
            vmType: guestType(osFamily: family, arch: image.arch),
            cpuCount: cpuCount(osFamily: family, hostCPUCount: hostCPUCount),
            memoryMB: memory,
            diskSizeGB: disk,
            isoId: iso ? image.id : nil,
            cloudImageId: iso ? nil : image.id,
            networkId: network?.id,
            workloadClass: klass,
            cloudInit: cloudInit,
            guestAddressing: guestAddressing,
        )
    }
}

/// Form state for bridged guest addressing, matching the SPA (#385). DHCP is the
/// default and sends nothing on create; static IPv4 is validated here and sent as
/// `guestAddressing` so the Device writes NoCloud network-config on the cloud-init ISO.
struct GuestAddressingDraft: Equatable {
    static let modeDHCP = "dhcp"
    static let modeStatic = "static"
    static let networkModeBridged = "bridged"
    static let defaultPrefixLength = 24

    var mode: String
    var ipv4: String
    var prefixLength: Int?
    var gateway: String
    /// Comma- or space-separated IPv4 list, same input shape as the SPA DNS field.
    var nameservers: String

    init(
        mode: String = modeDHCP,
        ipv4: String = "",
        prefixLength: Int? = defaultPrefixLength,
        gateway: String = "",
        nameservers: String = "",
    ) {
        self.mode = mode
        self.ipv4 = ipv4
        self.prefixLength = prefixLength
        self.gateway = gateway
        self.nameservers = nameservers
    }

    /// Prefill the edit form from the Workload's current addressing.
    init(info: GuestAddressingInfo?) {
        self.init(
            mode: info?.isStatic == true ? Self.modeStatic : Self.modeDHCP,
            ipv4: info?.ipv4 ?? "",
            prefixLength: info?.prefixLength ?? Self.defaultPrefixLength,
            gateway: info?.gateway ?? "",
            nameservers: (info?.nameservers ?? []).joined(separator: ", "),
        )
    }

    var isStatic: Bool {
        mode == Self.modeStatic
    }

    /// Create payload: DHCP (or an ineligible form) sends nothing. Static on NAT or an
    /// installer ISO is refused, same as the SPA and the server.
    func payload(bridged: Bool, cloudInit: Bool) throws -> GuestAddressingInfo? {
        guard isStatic else { return nil }
        guard bridged else { throw CreateWorkload.DraftError.staticAddressingNotBridged }
        guard cloudInit else { throw CreateWorkload.DraftError.staticAddressingNotCloudInit }
        return try validatedStatic()
    }

    /// Edit payload: DHCP is sent as `{ "mode": "dhcp" }` so static reverts to LAN DHCP.
    func editPayload() throws -> GuestAddressingInfo {
        guard isStatic else { return GuestAddressingInfo(mode: Self.modeDHCP) }
        return try validatedStatic()
    }

    private func validatedStatic() throws -> GuestAddressingInfo {
        let ip = ipv4.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIPv4(ip) else { throw CreateWorkload.DraftError.invalidGuestIPv4 }
        guard let prefix = prefixLength, (1 ... 32).contains(prefix) else {
            throw CreateWorkload.DraftError.invalidGuestPrefixLength
        }
        let gw = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIPv4(gw) else { throw CreateWorkload.DraftError.invalidGuestGateway }
        let servers = nameservers.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        for server in servers where !Self.isIPv4(server) {
            throw CreateWorkload.DraftError.invalidGuestNameserver
        }
        return GuestAddressingInfo(
            mode: Self.modeStatic,
            ipv4: ip,
            prefixLength: prefix,
            gateway: gw,
            nameservers: servers.isEmpty ? nil : servers,
        )
    }

    static func isIPv4(_ value: String) -> Bool {
        value.wholeMatch(of: ipv4Pattern) != nil
    }

    /// Same octet rule as the SPA `validateGuestAddressing`.
    private static let ipv4Pattern = #/(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}/#
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
