import Foundation

/// Magazine create flow aligned with the web `useCreateVMWizard` (Gallery → Configure → Disk).
enum CreateVMWizard {
    enum GalleryKind: String, Equatable {
        case template
        case windows
        case custom
        case codingAgent
    }

    enum Step: Int, CaseIterable {
        case gallery
        case configure
        case disk

        var title: String {
            switch self {
            case .gallery: "Gallery"
            case .configure: "Configure"
            case .disk: "Disk"
            }
        }
    }

    enum DiskSource: String, Equatable {
        case new
        case existing
    }

    struct SizePreset: Equatable, Identifiable {
        var id: String
        var label: String
        var cpu: Int
        var memoryMB: Int
        var diskGB: Int
    }

    static let presets: [SizePreset] = [
        .init(id: "small", label: "Small", cpu: 2, memoryMB: 4_096, diskGB: 32),
        .init(id: "medium", label: "Medium", cpu: 4, memoryMB: 8_192, diskGB: 64),
        .init(id: "large", label: "Large", cpu: 8, memoryMB: 16_384, diskGB: 128),
    ]

    static func clampedPresets(hostCPU: Int?, hostMemoryMB: Int?) -> [SizePreset] {
        let cpuCap = max(1, (hostCPU ?? 8) - hostCPUReserve(hostCPU ?? 8))
        let memCapMB = hostMemoryMB.map { max(128, $0 - 4_096) }
        return presets.map { preset in
            var row = preset
            row.cpu = min(row.cpu, cpuCap)
            if let memCapMB {
                row.memoryMB = min(row.memoryMB, max(128, memCapMB))
            }
            return row
        }
    }

    private static func hostCPUReserve(_ host: Int) -> Int {
        if host <= 1 { return 0 }
        if host < 4 { return 1 }
        return 2
    }

    static func windowsImage(in images: [LibraryImage]) -> LibraryImage? {
        CreateWorkload.ready(images).first { CreateWorkload.isWindowsImageName($0.name) }
    }

    static func codingAgentImage(in images: [LibraryImage]) -> LibraryImage? {
        CreateWorkload.ready(images).first { CodingAgentImage.matches(name: $0.name) }
    }

    static func defaultName(for kind: GalleryKind, template: VMTemplateRecord?) -> String {
        switch kind {
        case .template:
            template?.name.lowercased().replacingOccurrences(of: " ", with: "-") ?? "workload"
        case .windows: "windows"
        case .codingAgent: "agent"
        case .custom: "workload"
        }
    }

    static func templateInputsComplete(_ template: VMTemplateRecord, values: [String: String]) -> Bool {
        template.visibleInputs
            .filter { $0.required == true }
            .allSatisfy { input in
                let value = values[input.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if value.isEmpty { return false }
                if let min = input.minLength, value.count < min { return false }
                return true
            }
    }

    static func canProceedConfigure(
        kind: GalleryKind,
        name: String,
        device: HomeDeviceHealthSnapshot?,
        template: VMTemplateRecord?,
        templateInputs: [String: String],
        image: LibraryImage?,
        sshKey: SSHKeyRecord?,
        requiresSSH: Bool,
    ) -> Bool {
        guard device?.isReachable == true else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .template:
            guard let template else { return false }
            if template.declaresSSHKeys, sshKey == nil { return false }
            return templateInputsComplete(template, values: templateInputs)
        case .windows, .custom, .codingAgent:
            guard let image, image.isReady else { return false }
            if requiresSSH, sshKey == nil { return false }
            return true
        }
    }

    static func canCreate(
        kind: GalleryKind,
        diskSource: DiskSource,
        diskSizeGB: Int,
        existingDiskID: String,
        unusedDisks: [DiskRecord],
    ) -> Bool {
        switch diskSource {
        case .new: diskSizeGB >= 1
        case .existing:
            !existingDiskID.isEmpty && unusedDisks.contains { $0.id == existingDiskID }
        }
    }

    static func requiresSSH(kind: GalleryKind, template: VMTemplateRecord?, image: LibraryImage?) -> Bool {
        switch kind {
        case .template: template?.declaresSSHKeys == true
        case .windows: false
        case .codingAgent: false
        case .custom: image.map { !CreateWorkload.isISO($0) } ?? false
        }
    }

    static func deployInputs(
        template: VMTemplateRecord,
        values: [String: String],
        sshKey: SSHKeyRecord?,
    ) -> [String: String] {
        var inputs: [String: String] = [:]
        for input in template.visibleInputs {
            let value = values[input.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? input.default?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { inputs[input.id] = value }
        }
        if template.declaresSSHKeys, let sshKey {
            inputs["ssh_keys"] = sshKey.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return inputs
    }

    static func unusedDisks(_ disks: [DiskRecord]) -> [DiskRecord] {
        disks.filter { ($0.vmId ?? "").isEmpty && $0.status.lowercased() != "error" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension DiskRecord {
    var isUnused: Bool {
        (vmId ?? "").isEmpty && status.lowercased() != "error"
    }
}
