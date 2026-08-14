import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class WorkloadApplyServiceTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL
    private let hostLinux: String
    private let fixtureCPUCount: Int
    private let backgroundTasks = BackgroundTaskManager()

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
        hostLinux = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        fixtureCPUCount = min(2, max(1, PlatformHost.cpuCount))
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Parse / merge

    @Test func `parses json and yaml documents`() throws {
        let json = """
        {"apiVersion":"barkvisor.dev/v1","kind":"VirtualMachine","metadata":{"name":"web"},"spec":{"resources":{"cpu":1,"memoryMb":512}}}
        """
        let fromJSON = try WorkloadSpecDocument.parse(
            data: Data(json.utf8), contentType: "application/json",
        )
        #expect((fromJSON["metadata"] as? [String: Any])?["name"] as? String == "web")

        let yaml = """
        apiVersion: barkvisor.dev/v1
        kind: VirtualMachine
        metadata:
          name: web
        spec:
          resources:
            cpu: 1
            memoryMb: 512
        """
        let fromYAML = try WorkloadSpecDocument.parse(
            data: Data(yaml.utf8), contentType: "application/yaml",
        )
        let spec = try WorkloadSpecDocument.decode(fromYAML)
        #expect(spec.metadata.name == "web")
        #expect(spec.spec.resources.cpu == 1)
        #expect(spec.spec.resources.memoryMb == 512)
    }

    @Test func `ssa merge keeps omitted fields`() throws {
        let base = WorkloadSpec(
            metadata: WorkloadMetadata(id: "vm-1", name: "web", description: "keep me"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 1, memoryMb: 1_024),
                guestType: hostLinux,
            ),
        )
        let overlay: [String: Any] = [
            "spec": ["resources": ["cpu": fixtureCPUCount]],
        ]
        let merged = try WorkloadSpecDocument.merge(base: base, overlay: overlay)
        #expect(merged.spec.resources.cpu == fixtureCPUCount)
        #expect(merged.spec.resources.memoryMb == 1_024)
        #expect(merged.metadata.description == "keep me")
        #expect(merged.metadata.name == "web")
    }

    // MARK: - Apply

    @Test func `apply creates from a minimal spec then updates generation`() async throws {
        let diskID = try await insertFreeDisk(name: "boot-a")
        let createDoc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["name": "web"],
            "spec": [
                "resources": ["cpu": fixtureCPUCount, "memoryMb": 512],
                "disks": [["role": "boot", "diskId": diskID]],
            ],
        ]
        let created = try await WorkloadApplyService.apply(
            document: createDoc, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        #expect(created.op == .created)
        #expect(!created.id.isEmpty)
        #expect(created.generation == 1)

        let vm = try await fetchVM(created.id)
        #expect(vm.name == "web")
        #expect(vm.cpuCount == fixtureCPUCount)
        #expect(vm.memoryMb == 512)
        #expect(vm.vmType == hostLinux)
        #expect(vm.bootDiskId == diskID)

        let bump: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["name": "web"],
            "spec": ["resources": ["cpu": fixtureCPUCount, "memoryMb": 1_024]],
        ]
        let updated = try await WorkloadApplyService.apply(
            document: bump, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        #expect(updated.op == .updated)
        #expect(updated.id == created.id)
        #expect(updated.generation == 2)

        let after = try await fetchVM(created.id)
        #expect(after.memoryMb == 1_024)
        #expect(after.cpuCount == fixtureCPUCount)
        #expect(after.bootDiskId == diskID)

        let same = try await WorkloadApplyService.apply(
            document: bump, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        #expect(same.op == .unchanged)
        #expect(same.generation == 2)
        let unchanged = try await fetchVM(created.id)
        #expect(unchanged.specGeneration == 2)
    }

    @Test func `dryRun create and update leave the database unchanged`() async throws {
        let diskID = try await insertFreeDisk(name: "boot-dry")
        let createDoc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["name": "dry-web"],
            "spec": [
                "resources": ["cpu": fixtureCPUCount, "memoryMb": 512],
                "disks": [["role": "boot", "diskId": diskID]],
            ],
        ]
        let preview = try await WorkloadApplyService.apply(
            document: createDoc, dryRun: true, db: dbPool, backgroundTasks: backgroundTasks,
        )
        #expect(preview.op == .created)
        #expect(preview.generation == 1)
        #expect(preview.diff?.before == nil)
        #expect(try await vmCount() == 0)

        let created = try await WorkloadApplyService.apply(
            document: createDoc, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        let beforeGen = created.generation
        let patch: [String: Any] = [
            "metadata": ["name": "dry-web"],
            "spec": ["resources": ["memoryMb": 2_048]],
        ]
        let dryUpdate = try await WorkloadApplyService.apply(
            document: patch, dryRun: true, db: dbPool, backgroundTasks: backgroundTasks,
        )
        #expect(dryUpdate.op == .updated)
        #expect(dryUpdate.generation == beforeGen + 1)
        #expect(dryUpdate.diff?.after.spec.resources.memoryMb == 2_048)

        let live = try await fetchVM(created.id)
        #expect(live.memoryMb == 512)
        #expect(live.specGeneration == beforeGen)
        #expect(try await vmCount() == 1)
    }

    @Test func `yaml apply matches by metadata id`() async throws {
        let diskID = try await insertFreeDisk(name: "boot-yaml")
        let yaml = """
        apiVersion: barkvisor.dev/v1
        kind: VirtualMachine
        metadata:
          id: yaml-vm
          name: from-yaml
        spec:
          resources:
            cpu: \(fixtureCPUCount)
            memoryMb: 768
          disks:
            - role: boot
              diskId: \(diskID)
        """
        let document = try WorkloadSpecDocument.parse(
            data: Data(yaml.utf8), contentType: "text/yaml",
        )
        let created = try await WorkloadApplyService.apply(
            document: document, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        #expect(created.op == .created)
        #expect(created.id == "yaml-vm")
        let vm = try await fetchVM("yaml-vm")
        #expect(vm.name == "from-yaml")
        #expect(vm.memoryMb == 768)

        let exported = try await WorkloadApplyService.loadSpec(id: "yaml-vm", db: dbPool)
        #expect(exported.metadata.name == "from-yaml")
        #expect(exported.spec.resources.memoryMb == 768)
    }

    @Test func `unsupported kind is rejected`() async throws {
        let doc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": "Application",
            "metadata": ["name": "app"],
            "spec": ["resources": ["cpu": fixtureCPUCount, "memoryMb": 512]],
        ]
        do {
            _ = try await WorkloadApplyService.apply(
                document: doc, dryRun: true, db: dbPool, backgroundTasks: backgroundTasks,
            )
            Issue.record("expected unsupported kind to fail")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message.contains("VirtualMachine"))
        }
    }

    @Test func `metadata id path traversal is rejected`() async throws {
        let diskID = try await insertFreeDisk(name: "boot-traverse")
        let traversalID = ["..", "..", "..", "tmp", "evil"].joined(separator: "/")
        let doc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["id": traversalID, "name": "evil"],
            "spec": [
                "resources": ["cpu": fixtureCPUCount, "memoryMb": 512],
                "disks": [["role": "boot", "diskId": diskID]],
            ],
        ]
        var message: String?
        do {
            _ = try await WorkloadApplyService.apply(
                document: doc, dryRun: true, db: dbPool, backgroundTasks: backgroundTasks,
            )
            Issue.record("expected path-traversal metadata.id to fail")
        } catch let error as BarkVisorError {
            message = error.errorDescription
            #expect(error.httpStatus == 400)
        }
        #expect(message?.contains("metadata.id") == true)
        #expect(try await vmCount() == 0)
    }

    @Test func `create validation rejects path-traversal id`() async throws {
        let traversalID = ["..", "..", "..", "tmp", "evil"].joined(separator: "/")
        var message: String?
        do {
            try await VMLifecycleService.validateCreateVMInputs(
                params: CreateVMParams(
                    id: traversalID,
                    name: "evil",
                    vmType: hostLinux,
                    cpuCount: fixtureCPUCount,
                    memoryMB: 512,
                    isoId: "iso-1",
                ),
                db: dbPool,
            )
            Issue.record("expected path-traversal create id to fail")
        } catch let error as BarkVisorError {
            message = error.errorDescription
            #expect(error.httpStatus == 400)
        }
        #expect(message?.contains("VM id") == true)
    }

    @Test func `create without a boot disk or iso is rejected`() async throws {
        let doc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["name": "no-disk"],
            "spec": ["resources": ["cpu": fixtureCPUCount, "memoryMb": 512]],
        ]
        for dryRun in [true, false] {
            do {
                _ = try await WorkloadApplyService.apply(
                    document: doc, dryRun: dryRun, db: dbPool, backgroundTasks: backgroundTasks,
                )
                Issue.record("expected missing disk to fail (dryRun=\(dryRun))")
            } catch let BarkVisorError.badRequest(message) {
                #expect(message.contains("boot diskId") || message.contains("cdrom"))
            }
        }
        #expect(try await vmCount() == 0)
    }

    @Test func `dryRun create rejects a missing network`() async throws {
        let diskID = try await insertFreeDisk(name: "boot-missing-net")
        let doc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["name": "missing-net"],
            "spec": [
                "resources": ["cpu": fixtureCPUCount, "memoryMb": 512],
                "disks": [["role": "boot", "diskId": diskID]],
                "networks": [["networkId": "net-missing", "portForwards": []]],
            ],
        ]
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await WorkloadApplyService.apply(
                document: doc, dryRun: true, db: self.dbPool, backgroundTasks: self.backgroundTasks,
            )
        }
        #expect(error?.httpStatus == 404)
        #expect(try await vmCount() == 0)
    }

    @Test func `dryRun update rejects colliding port forwards`() async throws {
        let occupantDisk = try await insertFreeDisk(name: "boot-ha")
        let otherDisk = try await insertFreeDisk(name: "boot-other")
        let occupantDoc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["id": "vm-ha", "name": "Home Assistant"],
            "spec": [
                "resources": ["cpu": fixtureCPUCount, "memoryMb": 512],
                "disks": [["role": "boot", "diskId": occupantDisk]],
                "networks": [[
                    "mode": "nat",
                    "portForwards": [["hostPort": 8_123, "guestPort": 8_123, "proto": "tcp"]],
                ]],
            ],
        ]
        let otherDoc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["id": "vm-other", "name": "Other"],
            "spec": [
                "resources": ["cpu": fixtureCPUCount, "memoryMb": 512],
                "disks": [["role": "boot", "diskId": otherDisk]],
            ],
        ]
        _ = try await WorkloadApplyService.apply(
            document: occupantDoc, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        let created = try await WorkloadApplyService.apply(
            document: otherDoc, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        let patch: [String: Any] = [
            "metadata": ["id": "vm-other"],
            "spec": [
                "networks": [[
                    "mode": "nat",
                    "portForwards": [["hostPort": 8_123, "guestPort": 80, "proto": "tcp"]],
                ]],
            ],
        ]
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await WorkloadApplyService.apply(
                document: patch, dryRun: true, db: self.dbPool, backgroundTasks: self.backgroundTasks,
            )
        }
        #expect(error?.code == "port_in_use")
        #expect(error?.errorDescription?.contains("Home Assistant") == true)

        let live = try await fetchVM("vm-other")
        #expect(live.decodedPortForwards.isEmpty)
        #expect(live.specGeneration == created.generation)
        #expect(try await vmCount() == 2)
    }

    @Test func `apply health then explicit null clears persisted probes`() async throws {
        let diskID = try await insertFreeDisk(name: "boot-health")
        let createDoc: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["id": "vm-health", "name": "probed"],
            "spec": [
                "resources": ["cpu": fixtureCPUCount, "memoryMb": 512],
                "disks": [["role": "boot", "diskId": diskID]],
                "health": [
                    "http": ["path": "/health", "port": 8_080],
                ],
            ],
        ]
        _ = try await WorkloadApplyService.apply(
            document: createDoc, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        let created = try await fetchVM("vm-health")
        #expect(created.decodedHealth?.http?.port == 8_080)

        let omit: [String: Any] = [
            "metadata": ["id": "vm-health"],
            "spec": ["resources": ["memoryMb": 768]],
        ]
        _ = try await WorkloadApplyService.apply(
            document: omit, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        let kept = try await fetchVM("vm-health")
        #expect(kept.decodedHealth?.http?.port == 8_080)
        #expect(kept.memoryMb == 768)

        let clear: [String: Any] = [
            "metadata": ["id": "vm-health"],
            "spec": ["health": NSNull()],
        ]
        _ = try await WorkloadApplyService.apply(
            document: clear, dryRun: false, db: dbPool, backgroundTasks: backgroundTasks,
        )
        let after = try await fetchVM("vm-health")
        #expect(after.decodedHealth == nil)
        #expect(after.healthJson == nil)
    }

    // MARK: - Helpers

    private func insertFreeDisk(name: String) async throws -> String {
        let id = "disk-\(name)"
        let path = tmpDir.appendingPathComponent("\(id).qcow2")
        FileManager.default.createFile(atPath: path.path, contents: Data())
        try await dbPool.write { db in
            try Disk(
                id: id,
                name: name,
                path: path.path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        return id
    }

    private func fetchVM(_ id: String) async throws -> VM {
        try #require(try await dbPool.read { db in try VM.fetchOne(db, key: id) })
    }

    private func vmCount() async throws -> Int {
        try await dbPool.read { db in try VM.fetchCount(db) }
    }
}
