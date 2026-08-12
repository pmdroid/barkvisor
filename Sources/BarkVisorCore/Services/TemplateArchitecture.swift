import Foundation

/// Per-arch image resolution and compatibility for VM templates (PAS-33).
///
/// Catalogs declare `architectures` and optional `imageByArch`. Legacy
/// templates with only `imageSlug` infer a single arch from the slug suffix.
public enum TemplateArchitecture {
    /// Normalized arches this template can target, in declaration order.
    public static func declaredArchitectures(
        explicit: [String],
        imageByArch: [String: String],
        imageSlug: String,
    ) -> [String] {
        var seen: [String] = []
        func add(_ raw: String) {
            let normalized = PlatformCapabilities.normalizedArch(raw)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return }
            seen.append(normalized)
        }
        for arch in explicit {
            add(arch)
        }
        if seen.isEmpty {
            for key in imageByArch.keys {
                add(key)
            }
        }
        if seen.isEmpty, let inferred = inferArch(fromSlug: imageSlug) {
            add(inferred)
        }
        return seen
    }

    public static func supports(architectures: [String], arch: String) -> Bool {
        let want = PlatformCapabilities.normalizedArch(arch)
        if architectures.isEmpty { return true }
        return architectures.contains { PlatformCapabilities.normalizedArch($0) == want }
    }

    /// Image slug for `arch`, or nil when the template cannot target it.
    public static func resolveImageSlug(
        defaultSlug: String,
        imageByArch: [String: String],
        arch: String,
    ) -> String? {
        let want = PlatformCapabilities.normalizedArch(arch)
        for (key, slug) in imageByArch {
            if PlatformCapabilities.normalizedArch(key) == want, !slug.isEmpty {
                return slug
            }
        }
        let arches = declaredArchitectures(
            explicit: [], imageByArch: imageByArch, imageSlug: defaultSlug,
        )
        if !arches.isEmpty, !arches.contains(want) {
            return nil
        }
        if let inferred = inferArch(fromSlug: defaultSlug), inferred != want {
            return nil
        }
        return defaultSlug.isEmpty ? nil : defaultSlug
    }

    /// Infer guest arch from a catalog slug or filename (`ubuntu-24.04-arm64`).
    public static func inferArch(fromSlug slug: String) -> String? {
        let haystack = slug.lowercased().replacingOccurrences(of: "_", with: "-")
        if haystack.contains("x86-64") || haystack.contains("amd64")
            || haystack.range(of: #"(^|[^a-z0-9])x64([^a-z0-9]|$)"#, options: .regularExpression)
            != nil {
            return "x86_64"
        }
        if haystack.contains("aarch64") || haystack.contains("arm64") {
            return "arm64"
        }
        return nil
    }
}

public struct TemplateCompatibilityReason: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct TemplateCompatibilityReport: Codable, Sendable, Equatable {
    public let compatible: Bool
    public let hostId: String
    public let hostArch: String
    public let resolvedImageSlug: String?
    public let resolvedArch: String?
    public let reasons: [TemplateCompatibilityReason]
    public let missingFeatures: [String]
    public let minMemoryMB: Int?

    public init(
        compatible: Bool,
        hostId: String,
        hostArch: String,
        resolvedImageSlug: String?,
        resolvedArch: String?,
        reasons: [TemplateCompatibilityReason],
        missingFeatures: [String],
        minMemoryMB: Int?,
    ) {
        self.compatible = compatible
        self.hostId = hostId
        self.hostArch = hostArch
        self.resolvedImageSlug = resolvedImageSlug
        self.resolvedArch = resolvedArch
        self.reasons = reasons
        self.missingFeatures = missingFeatures
        self.minMemoryMB = minMemoryMB
    }
}

public enum TemplateCompatibility {
    public static func evaluate(
        template: VMTemplate,
        host: HostInventory,
        requestedMemoryMB: Int? = nil,
    ) -> TemplateCompatibilityReport {
        let hostArch = PlatformCapabilities.normalizedArch(host.platform.arch)
        let arches = template.declaredArchitectures
        var reasons: [TemplateCompatibilityReason] = []
        var missingFeatures: [String] = []

        if !TemplateArchitecture.supports(architectures: arches, arch: hostArch) {
            let listed = arches.isEmpty ? "unknown" : arches.joined(separator: ", ")
            reasons.append(
                TemplateCompatibilityReason(
                    code: "arch_unsupported",
                    message:
                    "This template supports \(listed), which is not compatible with this host (\(hostArch)).",
                ),
            )
        }

        let resolved = TemplateArchitecture.resolveImageSlug(
            defaultSlug: template.imageSlug,
            imageByArch: template.imageByArch,
            arch: hostArch,
        )
        if resolved == nil, reasons.allSatisfy({ $0.code != "arch_unsupported" }) {
            reasons.append(
                TemplateCompatibilityReason(
                    code: "image_unresolved",
                    message: "No catalog image is declared for host architecture \(hostArch).",
                ),
            )
        }

        for feature in template.requiredFeatures where !hostSupports(feature, inventory: host) {
            missingFeatures.append(feature)
            reasons.append(
                TemplateCompatibilityReason(
                    code: "feature_missing",
                    message: "This template requires \(feature), which is not available on this host.",
                ),
            )
        }

        if let min = template.minMemoryMB {
            let planned = requestedMemoryMB ?? template.memoryMB
            if planned < min {
                reasons.append(
                    TemplateCompatibilityReason(
                        code: "min_memory",
                        message: "This template requires at least \(min) MB of memory (requested \(planned)).",
                    ),
                )
            }
            if host.resources.memoryTotalMB < min {
                reasons.append(
                    TemplateCompatibilityReason(
                        code: "min_memory",
                        message:
                        "This host has \(host.resources.memoryTotalMB) MB RAM; the template requires \(min) MB.",
                    ),
                )
            }
        }

        return TemplateCompatibilityReport(
            compatible: reasons.isEmpty,
            hostId: host.hostId,
            hostArch: hostArch,
            resolvedImageSlug: resolved,
            resolvedArch: resolved == nil ? nil : hostArch,
            reasons: reasons,
            missingFeatures: missingFeatures,
            minMemoryMB: template.minMemoryMB,
        )
    }

    /// Wave 0: only the local host exists. Unknown `hostId` is a client error.
    public static func requireLocalHost(
        requestedHostId: String?,
        inventory: HostInventory,
    ) throws {
        guard let requestedHostId, !requestedHostId.isEmpty else { return }
        guard requestedHostId == inventory.hostId else {
            throw BarkVisorError.badRequest(
                "Unknown host '\(requestedHostId)'. This BarkVisor process only serves host \(inventory.hostId).",
            )
        }
    }

    public static func hostSupports(_ feature: String, inventory: HostInventory) -> Bool {
        let features = inventory.virtualization.features
        switch feature {
        case CapabilityCode.bridgedNetworking.rawValue:
            return features.bridgedNetworking
        case CapabilityCode.managedBridgeDaemon.rawValue:
            return features.managedBridgeDaemon
        case CapabilityCode.usbPassthrough.rawValue:
            return features.usbPassthrough
        case CapabilityCode.inAppUpdate.rawValue:
            return features.inAppUpdate
        case CapabilityCode.kvmDevice.rawValue:
            return features.kvmDevice
        case CapabilityCode.qemuBridgeHelper.rawValue:
            return features.qemuBridgeHelper
        default:
            return false
        }
    }
}
