import Foundation
import GRDB

public enum WorkloadApplyOp: String, Codable, Sendable {
    case created
    case updated
    case unchanged
}

public struct WorkloadApplyDiff: Codable, Equatable, Sendable {
    public var before: WorkloadSpec?
    public var after: WorkloadSpec

    public init(before: WorkloadSpec?, after: WorkloadSpec) {
        self.before = before
        self.after = after
    }
}

/// `POST /api/workloads/apply` result (PAS-80).
public struct WorkloadApplyResult: Codable, Equatable, Sendable {
    public var op: WorkloadApplyOp
    public var id: String
    public var generation: Int
    public var diff: WorkloadApplyDiff?

    public init(op: WorkloadApplyOp, id: String, generation: Int, diff: WorkloadApplyDiff? = nil) {
        self.op = op
        self.id = id
        self.generation = generation
        self.diff = diff
    }
}

/// Server-side apply for WorkloadSpec documents (create / update / dry-run).
public enum WorkloadApplyService {
    public static let defaultCreateDiskSizeGB = 20

    public static func apply(
        document: [String: Any],
        dryRun: Bool,
        db: DatabasePool,
        backgroundTasks: BackgroundTaskManager,
    ) async throws -> WorkloadApplyResult {
        try validateDocumentEnvelope(document)
        let existing = try await findExisting(document: document, db: db)
        if let existing {
            return try await applyUpdate(document: document, existing: existing, dryRun: dryRun, db: db)
        }
        return try await applyCreate(
            document: document,
            dryRun: dryRun,
            db: db,
            backgroundTasks: backgroundTasks,
        )
    }

    public static func loadSpec(id: String, db: DatabasePool) async throws -> WorkloadSpec {
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw BarkVisorError.notFound("Workload not found")
        }
        return WorkloadSpecProjector.fromVM(vm)
    }

    // MARK: - Match

    static func findExisting(document: [String: Any], db: DatabasePool) async throws -> VM? {
        let metadata = metadataObject(document)
        if let id = stringValue(metadata["id"]), !id.isEmpty {
            return try await db.read { db in try VM.fetchOne(db, key: id) }
        }
        let name = stringValue(metadata["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let matches = try await db.read { db in
            try VM.filter(Column("name") == name).fetchAll(db)
        }
        if matches.count > 1 {
            throw BarkVisorError.conflict(
                "Multiple workloads named '\(name)'; set metadata.id to choose one",
            )
        }
        return matches.first
    }

    // MARK: - Update

    private static func applyUpdate(
        document: [String: Any],
        existing: VM,
        dryRun: Bool,
        db: DatabasePool,
    ) async throws -> WorkloadApplyResult {
        let before = WorkloadSpecProjector.fromVM(existing)
        let merged = try WorkloadSpecDocument.merge(base: before, overlay: document)
        var preview = existing
        try WorkloadSpecProjector.apply(merged, to: &preview)
        let after = WorkloadSpecProjector.fromVM(preview)
        if after == before {
            return WorkloadApplyResult(
                op: .unchanged,
                id: existing.id,
                generation: existing.specGeneration,
                diff: dryRun ? WorkloadApplyDiff(before: before, after: after) : nil,
            )
        }
        if dryRun {
            return WorkloadApplyResult(
                op: .updated,
                id: existing.id,
                generation: existing.specGeneration + 1,
                diff: WorkloadApplyDiff(before: before, after: after),
            )
        }
        let vm = try await VMLifecycleService.updateVMSpec(id: existing.id, spec: merged, db: db)
        return WorkloadApplyResult(
            op: .updated,
            id: vm.id,
            generation: vm.specGeneration,
            diff: WorkloadApplyDiff(before: before, after: WorkloadSpecProjector.fromVM(vm)),
        )
    }

    // MARK: - Create

    private static func applyCreate(
        document: [String: Any],
        dryRun: Bool,
        db: DatabasePool,
        backgroundTasks: BackgroundTaskManager,
    ) async throws -> WorkloadApplyResult {
        let spec = try WorkloadSpecDocument.decode(document)
        try WorkloadSpecProjector.validate(spec)
        if dryRun {
            let previewID = spec.metadata.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return WorkloadApplyResult(
                op: .created,
                id: previewID,
                generation: 1,
                diff: WorkloadApplyDiff(before: nil, after: spec),
            )
        }
        let params = try createParams(from: spec)
        if let requested = params.id, !requested.isEmpty {
            let taken = try await db.read { db in try VM.fetchOne(db, key: requested) }
            if taken != nil {
                throw BarkVisorError.conflict("Workload \(requested) already exists")
            }
        }
        let result = try await VMLifecycleService.createVM(
            params: params, db: db, backgroundTasks: backgroundTasks,
        )
        let vm: VM = switch result {
        case let .created(vm): vm
        case let .provisioning(_, vm): vm
        }
        return WorkloadApplyResult(
            op: .created,
            id: vm.id,
            generation: vm.specGeneration,
            diff: WorkloadApplyDiff(before: nil, after: WorkloadSpecProjector.fromVM(vm)),
        )
    }

    static func createParams(from spec: WorkloadSpec) throws -> CreateVMParams {
        let guestType = try WorkloadSpecProjector.resolveGuestType(spec)
        let bootDiskId = spec.spec.disks.first(where: { $0.role == "boot" })?.diskId
        let isoFromSpec = spec.spec.disks.first(where: { $0.role == "cdrom" })?.imageId
            ?? spec.spec.disks.first(where: { $0.role == "cdrom" })?.diskId
        if bootDiskId == nil || bootDiskId?.isEmpty == true,
           isoFromSpec == nil || isoFromSpec?.isEmpty == true {
            throw BarkVisorError.badRequest(
                "Creating a workload requires spec.disks with a boot diskId or a cdrom imageId",
            )
        }
        let forwards = spec.spec.networks.first?.portForwards.map {
            PortForwardRule(protocol: $0.proto, hostPort: $0.hostPort, guestPort: $0.guestPort)
        }
        let usb = spec.spec.usb.map {
            USBPassthroughDevice(vendorId: $0.vendorId, productId: $0.productId, label: $0.label)
        }
        let requestedID = spec.metadata.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreateVMParams(
            id: requestedID?.isEmpty == true ? nil : requestedID,
            name: spec.metadata.name,
            vmType: guestType,
            cpuCount: spec.spec.resources.cpu,
            memoryMB: spec.spec.resources.memoryMb,
            diskSizeGB: isoFromSpec == nil ? nil : defaultCreateDiskSizeGB,
            isoId: isoFromSpec,
            cloudInit: cloudInitConfig(from: spec.spec.cloudInit),
            networkId: spec.spec.networks.first?.networkId,
            existingDiskId: bootDiskId,
            sharedPaths: spec.spec.sharedPaths,
            portForwards: forwards,
            usbDevices: usb.isEmpty ? nil : usb,
            description: spec.metadata.description,
            bootOrder: spec.spec.bootOrder,
            displayResolution: spec.spec.display?.resolution,
            uefi: spec.spec.firmware?.uefi,
            tpmEnabled: spec.spec.firmware?.tpm,
            overrides: spec.overrides,
        )
    }

    /// `spec.cloudInit.inline` is user-data for ISO generation.
    static func cloudInitConfig(from cloud: WorkloadCloudInit?) -> CloudInitConfig? {
        guard let inline = cloud?.inline,
              !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CloudInitConfig(sshAuthorizedKeys: nil, userData: inline)
    }

    // MARK: - Envelope

    private static func validateDocumentEnvelope(_ document: [String: Any]) throws {
        if let apiVersion = stringValue(document["apiVersion"]),
           apiVersion != WorkloadSpec.currentAPIVersion {
            throw BarkVisorError.badRequest(
                "Unsupported apiVersion \(apiVersion). Expected \(WorkloadSpec.currentAPIVersion)",
            )
        }
        if let kind = stringValue(document["kind"]), kind != WorkloadSpec.kindVirtualMachine {
            throw BarkVisorError.badRequest(
                "Unsupported kind \(kind). Expected \(WorkloadSpec.kindVirtualMachine)",
            )
        }
        let metadata = metadataObject(document)
        if let id = stringValue(metadata["id"]), id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BarkVisorError.badRequest("metadata.id must not be empty when set")
        }
        let name = stringValue(metadata["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty, stringValue(metadata["id"]) == nil {
            throw BarkVisorError.badRequest("metadata.name or metadata.id is required")
        }
    }

    private static func metadataObject(_ document: [String: Any]) -> [String: Any] {
        document["metadata"] as? [String: Any] ?? [:]
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return nil
    }
}
