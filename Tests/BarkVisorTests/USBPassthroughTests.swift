import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct USBPassthroughTests {
    @Test func `stable id prefers serial over bus address`() {
        let withSerial = USBDeviceIdentity.make(
            vendorId: "046d", productId: "c52b", serial: "ABC 123", bus: 1, address: 4,
        )
        #expect(withSerial.id == "0x046d:0xc52b:ABC%20123")
        #expect(!withSerial.unstable)
        #expect(withSerial.serial == "ABC 123")

        let parsed = USBDeviceIdentity.parse(withSerial.id)
        #expect(parsed?.serial == "ABC 123")
        #expect(parsed?.vendorId == "0x046d")
        #expect(parsed?.productId == "0xc52b")
    }

    @Test func `bus id is marked unstable`() {
        let ref = USBDeviceIdentity.make(
            vendorId: "0x1234", productId: "0x5678", serial: nil, bus: 2, address: 9,
        )
        #expect(ref.id == "bus:002.009")
        #expect(ref.unstable)
        let parsed = USBDeviceIdentity.parse(ref.id)
        #expect(parsed?.bus == 2)
        #expect(parsed?.address == 9)
        #expect(parsed?.unstable == true)
    }

    @Test func `legacy vid pid still decodes`() throws {
        let json = Data(#"{"vendorId":"0x1234","productId":"0x5678","label":"stick"}"#.utf8)
        let device = try JSONDecoder().decode(USBPassthroughDevice.self, from: json)
        #expect(device.vendorId == "0x1234")
        #expect(device.productId == "0x5678")
        #expect(device.serialNumber == nil)
        #expect(device.deviceId == nil)
    }

    @Test func `sysfs listing reads serial and excludes mass storage`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usb-sysfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSysfsDevice(
            at: root.appendingPathComponent("1-1"),
            vendor: "046d",
            product: "c52b",
            bus: "1",
            address: "4",
            serial: "SN-111",
            productName: "Unifying Receiver",
            manufacturer: "Logitech",
            interfaceClass: "03",
        )
        try writeSysfsDevice(
            at: root.appendingPathComponent("1-2"),
            vendor: "0781",
            product: "5567",
            bus: "1",
            address: "5",
            serial: "SN-DISK",
            productName: "Cruzer",
            manufacturer: "SanDisk",
            interfaceClass: "08",
        )
        // Same vid:pid, different serial — must stay distinct.
        try writeSysfsDevice(
            at: root.appendingPathComponent("1-3"),
            vendor: "046d",
            product: "c52b",
            bus: "1",
            address: "6",
            serial: "SN-222",
            productName: "Unifying Receiver",
            manufacturer: "Logitech",
            interfaceClass: "03",
        )

        let devices = USBDeviceService.listSysfsDevices(root: root)
        #expect(devices.count == 3)
        let first = devices.first { $0.serialNumber == "SN-111" }
        let second = devices.first { $0.serialNumber == "SN-222" }
        let disk = devices.first { $0.serialNumber == "SN-DISK" }
        #expect(first?.id == "0x046d:0xc52b:SN-111")
        #expect(first?.idUnstable == false)
        #expect(first?.attachable == true)
        #expect(second?.id == "0x046d:0xc52b:SN-222")
        #expect(disk?.attachable == false)
        #expect(disk?.excludedReason == USBDeviceIdentity.massStorageExclusionReason)
    }

    @Test func `claim map uses serial so two identical vid pid stay distinct`() {
        let hostA = HostUSBDevice(
            vendorId: "0x046d", productId: "0xc52b", name: "Receiver",
            manufacturer: "Logitech", serialNumber: "AAA", bus: 1, address: 4,
        )
        let hostB = HostUSBDevice(
            vendorId: "0x046d", productId: "0xc52b", name: "Receiver",
            manufacturer: "Logitech", serialNumber: "BBB", bus: 1, address: 5,
        )
        var vm = makeVM(usb: [USBPassthroughService.passthrough(from: hostA)])
        vm.name = "htpc"
        let claimedA = USBPassthroughService.claimedBy(host: hostA, vms: [vm])
        let claimedB = USBPassthroughService.claimedBy(host: hostB, vms: [vm])
        #expect(claimedA?.id == vm.id)
        #expect(claimedA?.name == "htpc")
        #expect(claimedB == nil)
    }

    @Test func `normalize rejects ambiguous vid pid without serial`() {
        let hosts = [
            HostUSBDevice(
                vendorId: "0x046d", productId: "0xc52b", name: "A",
                manufacturer: nil, serialNumber: "AAA", bus: 1, address: 4,
            ),
            HostUSBDevice(
                vendorId: "0x046d", productId: "0xc52b", name: "B",
                manufacturer: nil, serialNumber: "BBB", bus: 1, address: 5,
            ),
        ]
        let err = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.normalizeOne(
                USBPassthroughDevice(vendorId: "0x046d", productId: "0xc52b", label: "recv"),
                hostDevices: hosts,
            )
        }
        if case let .conflict(message) = err {
            #expect(message.contains("Multiple USB devices"))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `attach by stable id and detach leave occupancy clear`() throws {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: "Acme", serialNumber: "ZX9", bus: 3, address: 2,
        )
        let resolved = try USBPassthroughService.resolveAttachable(
            deviceId: host.id, hostDevices: [host],
        )
        #expect(resolved.id == "0x1234:0x5678:ZX9")
        let stored = USBPassthroughService.passthrough(from: resolved)
        let remaining = USBPassthroughService.removing([stored], deviceId: host.id)
        #expect(remaining.isEmpty)
    }

    @Test func `qemu args use hostbus when serial resolves`() throws {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: nil, serialNumber: "ZX9", bus: 3, address: 2,
        )
        let usb = [
            WorkloadUSBDevice(
                vendorId: "0x1234", productId: "0x5678", label: "Probe",
                serialNumber: "ZX9", deviceId: host.id,
            ),
        ]
        let args = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [host])
        #expect(args.contains("-device"))
        #expect(args.contains { $0.contains("usb-host,hostbus=3,hostaddr=2") })
        #expect(!args.contains { $0.contains("vendorid=") })
    }

    @Test func `qemu args fail closed for legacy vendor product attachments`() {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: nil, serialNumber: nil, bus: 3, address: 2,
        )
        let usb = [WorkloadUSBDevice(vendorId: "0x1234", productId: "0x5678", label: "legacy")]
        let err = #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [host])
        }
        if case let .conflict(message) = err {
            #expect(message.contains("Re-attach"))
            #expect(!message.contains("vendorid="))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `qemu args use hostbus when bus id resolves and is attachable`() throws {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: nil, serialNumber: nil, bus: 3, address: 2,
        )
        let usb = [
            WorkloadUSBDevice(
                vendorId: "0x1234", productId: "0x5678", label: "Probe",
                deviceId: host.id,
            ),
        ]
        let args = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [host])
        #expect(args.contains { $0.contains("usb-host,hostbus=3,hostaddr=2") })
        #expect(!args.contains { $0.contains("vendorid=") })
    }

    @Test func `qemu args fail closed for stale bus address without host`() {
        let usb = [
            WorkloadUSBDevice(
                vendorId: "0x1234", productId: "0x5678", label: "Probe",
                deviceId: "bus:003.002",
            ),
        ]
        let err = #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [])
        }
        if case let .notFound(message) = err {
            #expect(message?.contains("bus:003.002") == true)
        } else {
            Issue.record("expected notFound, got \(String(describing: err))")
        }
    }

    @Test func `qemu args fail closed when bus id resolves to excluded device`() {
        let disk = HostUSBDevice(
            vendorId: "0x0781", productId: "0x5567", name: "Cruzer",
            manufacturer: "SanDisk", serialNumber: nil, bus: 1, address: 8,
            attachable: false, excludedReason: USBDeviceIdentity.massStorageExclusionReason,
        )
        let usb = [
            WorkloadUSBDevice(
                vendorId: "0x0781", productId: "0x5567", label: "Cruzer",
                deviceId: disk.id,
            ),
        ]
        let err = #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [disk])
        }
        if case let .badRequest(message) = err {
            #expect(message.contains("mass storage"))
            #expect(!message.contains("vendorid="))
        } else {
            Issue.record("expected badRequest, got \(String(describing: err))")
        }
    }

    @Test func `qemu args fail closed when serial device is missing`() {
        let usb = [
            WorkloadUSBDevice(
                vendorId: "0x1234", productId: "0x5678", label: "Probe",
                serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
            ),
        ]
        #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [])
        }
    }

    @Test func `qemu args fail closed when serial device has no bus address`() {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: nil, serialNumber: "ZX9",
        )
        let usb = [
            WorkloadUSBDevice(
                vendorId: "0x1234", productId: "0x5678", label: "Probe",
                serialNumber: "ZX9", deviceId: host.id,
            ),
        ]
        let err = #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [host])
        }
        if case let .conflict(message) = err {
            #expect(message.contains("bus/address"))
            #expect(!message.contains("vendorid="))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `macos address ignores PortNum fallback`() {
        let portOnly: [String: Any] = ["PortNum": 3]
        #expect(USBDeviceService.parseIORegistryUSBAddress(portOnly) == nil)
        #expect(USBDeviceService.parseIORegistryUSBBus(portOnly) == nil)

        let withAddress: [String: Any] = ["USB Address": 7, "PortNum": 3, "Bus Number": 1]
        #expect(USBDeviceService.parseIORegistryUSBAddress(withAddress) == 7)
        #expect(USBDeviceService.parseIORegistryUSBBus(withAddress) == 1)
    }

    @Test func `macos bus falls back to locationID high byte`() {
        // Real IOUSBHostDevice entries (e.g. EXCERIA PLUS@03200000) have
        // USB Address + locationID and no "Bus Number" key.
        let realDevice: [String: Any] = [
            "USB Address": 1,
            "locationID": 0x0320_0000,
        ]
        #expect(USBDeviceService.parseIORegistryUSBAddress(realDevice) == 1)
        #expect(USBDeviceService.parseIORegistryUSBBus(realDevice) == 3)

        let highBus: [String: Any] = ["locationID": 0x8200_0000 as UInt32]
        #expect(USBDeviceService.parseIORegistryUSBBus(highBus) == 0x82)

        let explicitBusWins: [String: Any] = [
            "Bus Number": 1,
            "locationID": 0x0320_0000,
        ]
        #expect(USBDeviceService.parseIORegistryUSBBus(explicitBusWins) == 1)
    }

    @Test func `assertUnclaimed rejects device already attached to another VM`() {
        let device = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        var occupant = makeVM(usb: [device])
        occupant.name = "htpc"
        let err = #expect(throws: BarkVisorError.self) {
            try USBPassthroughService.assertUnclaimed(devices: [device], vms: [occupant])
        }
        if case let .conflict(message) = err {
            #expect(message.contains("htpc"))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `assertUnclaimed allows the owning VM to keep its device`() throws {
        let device = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        let occupant = makeVM(usb: [device])
        try USBPassthroughService.assertUnclaimed(
            devices: [device], vms: [occupant], excludingVMId: occupant.id,
        )
    }

    @Test func `projector preserves serial and device id`() {
        var vm = makeVM(usb: [
            USBPassthroughDevice(
                vendorId: "0x1234", productId: "0x5678", label: "stick",
                serialNumber: "SN1", deviceId: "0x1234:0x5678:SN1",
            ),
        ])
        let spec = WorkloadSpecProjector.fromVM(vm)
        #expect(spec.spec.usb.first?.serialNumber == "SN1")
        #expect(spec.spec.usb.first?.deviceId == "0x1234:0x5678:SN1")
        try? WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.decodedUSBDevices.first?.serialNumber == "SN1")
        #expect(vm.decodedUSBDevices.first?.deviceId == "0x1234:0x5678:SN1")
    }

    @Test func `mass storage cannot be attached by id`() {
        let disk = HostUSBDevice(
            vendorId: "0x0781", productId: "0x5567", name: "Cruzer",
            manufacturer: "SanDisk", serialNumber: "DISK1", bus: 1, address: 8,
            attachable: false, excludedReason: USBDeviceIdentity.massStorageExclusionReason,
        )
        let err = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.resolveAttachable(
                deviceId: disk.id, hostDevices: [disk],
            )
        }
        if case let .badRequest(message) = err {
            #expect(message.contains("mass storage"))
        } else {
            Issue.record("expected badRequest, got \(String(describing: err))")
        }
    }

    private func makeVM(usb: [USBPassthroughDevice]) -> VM {
        let cpu = min(2, max(1, PlatformHost.cpuCount))
        return VM(
            id: "vm-usb-1",
            name: "usb-vm",
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: cpu,
            memoryMb: 1_024,
            bootDiskId: "disk-1",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            usbDevices: JSONColumnCoding.encode(usb),
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2020-01-01T00:00:00Z",
            updatedAt: "2020-01-01T00:00:00Z",
        )
    }

    private func writeSysfsDevice(
        at directory: URL,
        vendor: String,
        product: String,
        bus: String,
        address: String,
        serial: String,
        productName: String,
        manufacturer: String,
        interfaceClass: String,
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ name: String, _ value: String) throws {
            try value.write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8,
            )
        }
        try write("idVendor", vendor)
        try write("idProduct", product)
        try write("busnum", bus)
        try write("devnum", address)
        try write("serial", serial)
        try write("product", productName)
        try write("manufacturer", manufacturer)
        try write("bDeviceClass", "00")
        let iface = directory.appendingPathComponent("\(directory.lastPathComponent):1.0")
        try FileManager.default.createDirectory(at: iface, withIntermediateDirectories: true)
        try interfaceClass.write(
            to: iface.appendingPathComponent("bInterfaceClass"),
            atomically: true,
            encoding: .utf8,
        )
    }
}

final class USBClaimWriteTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL
    private let hostLinux: String
    private let fixtureCPUCount: Int

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

    @Test func `updateVM rejects USB claimed by another VM`() async throws {
        let device = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        try await insertVM(id: "vm-htpc", name: "htpc", usb: [device])
        try await insertVM(id: "vm-other", name: "other", usb: nil)
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.updateVM(
                id: "vm-other",
                params: UpdateVMParams(usbDevices: [device]),
                db: self.dbPool,
            )
        }
        #expect(error?.code == "conflict")
        #expect(error?.httpStatus == 409)
        #expect(error?.errorDescription?.contains("htpc") == true)
    }

    @Test func `updateVM can keep its own USB devices`() async throws {
        let device = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        try await insertVM(id: "vm-htpc", name: "htpc", usb: [device])
        let updated = try await VMLifecycleService.updateVM(
            id: "vm-htpc",
            params: UpdateVMParams(usbDevices: [device], description: "still mine"),
            db: dbPool,
        )
        #expect(updated.description == "still mine")
        #expect(updated.decodedUSBDevices.first?.deviceId == device.deviceId)
    }

    @Test func `updateVMSpec rejects ambiguous vid pid without serial`() async throws {
        let hosts = [
            HostUSBDevice(
                vendorId: "0x046d", productId: "0xc52b", name: "A",
                manufacturer: nil, serialNumber: "AAA", bus: 1, address: 4,
            ),
            HostUSBDevice(
                vendorId: "0x046d", productId: "0xc52b", name: "B",
                manufacturer: nil, serialNumber: "BBB", bus: 1, address: 5,
            ),
        ]
        try await insertVM(id: "vm-spec", name: "spec-vm", usb: nil)
        let existing = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-spec") }
        let vm = try #require(existing)
        var spec = WorkloadSpecProjector.fromVM(vm)
        spec.spec.guestType = hostLinux
        spec.spec.usb = [
            WorkloadUSBDevice(vendorId: "0x046d", productId: "0xc52b", label: "recv"),
        ]
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.updateVMSpec(
                id: "vm-spec", spec: spec, db: self.dbPool, hostDevices: hosts,
            )
        }
        #expect(error?.code == "conflict")
        #expect(error?.errorDescription?.contains("Multiple USB devices") == true)
        let stored = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-spec") }
        #expect(stored?.decodedUSBDevices.isEmpty == true)
    }

    @Test func `updateVMSpec rejects USB claimed by another VM`() async throws {
        let device = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        try await insertVM(id: "vm-htpc", name: "htpc", usb: [device])
        try await insertVM(id: "vm-other", name: "other", usb: nil)
        let other = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-other") }
        let occupant = try #require(other)
        var spec = WorkloadSpecProjector.fromVM(occupant)
        spec.spec.guestType = hostLinux
        spec.spec.usb = [USBPassthroughService.workload(from: device)]
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.updateVMSpec(
                id: "vm-other", spec: spec, db: self.dbPool,
            )
        }
        #expect(error?.code == "conflict")
        #expect(error?.errorDescription?.contains("htpc") == true)
    }

    @Test func `create validation rejects USB claimed by another VM`() async throws {
        let device = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        try await insertVM(id: "vm-htpc", name: "htpc", usb: [device])
        let error = await #expect(throws: BarkVisorError.self) {
            try await VMLifecycleService.validateCreateVMInputs(
                params: CreateVMParams(
                    name: "second",
                    vmType: self.hostLinux,
                    cpuCount: self.fixtureCPUCount,
                    memoryMB: 512,
                    isoId: "iso-1",
                    usbDevices: [device],
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.code == "conflict")
        #expect(error?.errorDescription?.contains("htpc") == true)
    }

    private func insertVM(
        id: String,
        name: String,
        usb: [USBPassthroughDevice]?,
    ) async throws {
        let diskPath = tmpDir.appendingPathComponent("\(id).qcow2").path
        let vmType = hostLinux
        let cpuCount = fixtureCPUCount
        try await dbPool.write { db in
            let disk = Disk(
                id: "disk-\(id)",
                name: "boot",
                path: diskPath,
                sizeBytes: 1_000_000,
                format: "qcow2",
                vmId: id,
                autoCreated: false,
                status: "ready",
                createdAt: "2026-01-01T00:00:00Z",
            )
            try disk.insert(db)
            let vm = VM(
                id: id,
                name: name,
                vmType: vmType,
                state: "stopped",
                cpuCount: cpuCount,
                memoryMb: 512,
                bootDiskId: disk.id,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: JSONColumnCoding.encode(usb),
                autoCreated: false,
                pendingChanges: false,
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
            )
            try vm.insert(db)
        }
    }
}
