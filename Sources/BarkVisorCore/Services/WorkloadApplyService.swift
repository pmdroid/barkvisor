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
        if let kind = stringValue(document["kind"]), kind != existing.kind {
            throw BarkVisorError.badRequest("kind cannot change after create")
        }
        let effective = try EffectiveWorkloadPipeline.evaluate(
            document: document,
            existing: existing,
        )
        let merged = effective.portable
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
            let projected = preview
            if !projected.isApplication {
                try await db.read { db in
                    try VMLifecycleService.validateAppliedVMSpec(spec: merged, vm: projected, db: db)
                }
            }
            return WorkloadApplyResult(
                op: .updated,
                id: existing.id,
                generation: existing.specGeneration + 1,
                diff: WorkloadApplyDiff(before: before, after: after),
            )
        }
        var vm = try await VMLifecycleService.updateVMSpec(id: existing.id, spec: merged, db: db)
        if vm.isApplication {
            try await ApplicationLifecycleService.syncProject(vm: &vm, db: db)
        }
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
        if spec.kind == WorkloadSpec.kindApplication {
            return try await applyCreateApplication(spec: spec, dryRun: dryRun, db: db)
        }
        let params = try EffectiveWorkloadPipeline.createParams(from: spec, extras: .apply)
        try await VMLifecycleService.validateCreateVMInputs(params: params, db: db)
        if dryRun {
            let previewID = spec.metadata.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return WorkloadApplyResult(
                op: .created,
                id: previewID,
                generation: 1,
                diff: WorkloadApplyDiff(before: nil, after: spec),
            )
        }
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

    private static func applyCreateApplication(
        spec: WorkloadSpec,
        dryRun: Bool,
        db: DatabasePool,
    ) async throws -> WorkloadApplyResult {
        try WorkloadSpecProjector.validate(spec)
        try DockerEngine.requireDeviceRuntime()
        let requested = spec.metadata.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = requested.isEmpty ? UUID().uuidString : requested
        try validateVMID(id, label: "metadata.id")
        if dryRun {
            return WorkloadApplyResult(
                op: .created,
                id: id,
                generation: 1,
                diff: WorkloadApplyDiff(before: nil, after: spec),
            )
        }
        let taken = try await db.read { db in try VM.fetchOne(db, key: id) }
        if taken != nil {
            throw BarkVisorError.conflict("Workload \(id) already exists")
        }
        let now = iso8601.string(from: Date())
        var vm = VM(
            id: id,
            name: spec.metadata.name,
            vmType: WorkloadSpec.applicationGuestType,
            state: "stopped",
            cpuCount: spec.spec.resources.cpu,
            memoryMb: spec.spec.resources.memoryMb,
            bootDiskId: nil,
            kind: WorkloadSpec.kindApplication,
            runtime: spec.spec.runtime ?? WorkloadSpec.runtimeDevice,
            runtimeWorkloadId: spec.spec.runtimeWorkloadId,
            composeYaml: spec.spec.compose,
            composeProject: ComposeRuntime.composeProjectName(id: id),
            isoIds: nil,
            networkId: nil,
            cloudInitPath: nil,
            description: spec.metadata.description,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: false,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            startOnBoot: true,
            createdAt: now,
            updatedAt: now,
        )
        vm.setHealth(spec.spec.health)
        var document = spec
        document.metadata.id = id
        vm.specJson = WorkloadSpecJSON.encode(document)
        vm.syncSpecProjection(bumpGeneration: false)
        let row = vm
        try await db.write { db in
            try row.insert(db)
        }
        do {
            try await ApplicationLifecycleService.start(vm: &vm, db: db)
        } catch {
            Log.vm.warning(
                "Application \(vm.id) compose up failed: \(error.localizedDescription)",
                vm: vm.id,
            )
        }
        let persisted = try await db.read { db in try VM.fetchOne(db, key: id) } ?? vm
        return WorkloadApplyResult(
            op: .created,
            id: persisted.id,
            generation: persisted.specGeneration,
            diff: WorkloadApplyDiff(before: nil, after: WorkloadSpecProjector.fromVM(persisted)),
        )
    }

    static func createParams(from spec: WorkloadSpec) throws -> CreateVMParams {
        try EffectiveWorkloadPipeline.createParams(from: spec, extras: .apply)
    }

    // MARK: - Envelope

    private static func validateDocumentEnvelope(_ document: [String: Any]) throws {
        if let apiVersion = stringValue(document["apiVersion"]),
           apiVersion != WorkloadSpec.currentAPIVersion {
            throw BarkVisorError.badRequest(
                "Unsupported apiVersion \(apiVersion). Expected \(WorkloadSpec.currentAPIVersion)",
            )
        }
        if let kind = stringValue(document["kind"]) {
            let allowed = [WorkloadSpec.kindVirtualMachine, WorkloadSpec.kindApplication]
            if !allowed.contains(kind) {
                throw BarkVisorError.badRequest(
                    "Unsupported kind \(kind). Expected \(WorkloadSpec.kindVirtualMachine) or \(WorkloadSpec.kindApplication)",
                )
            }
        }
        let metadata = metadataObject(document)
        if let id = stringValue(metadata["id"]) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw BarkVisorError.badRequest("metadata.id must not be empty when set")
            }
            try validateVMID(trimmed, label: "metadata.id")
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
