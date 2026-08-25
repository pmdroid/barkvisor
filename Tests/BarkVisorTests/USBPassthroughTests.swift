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

    @Test func `lsusb fallback prefers sysfs serial for that bus address`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usb-lsusb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSysfsDevice(
            at: root.appendingPathComponent("3-2"),
            vendor: "1234",
            product: "5678",
            bus: "3",
            address: "2",
            serial: "ZX9",
            productName: "Probe",
            manufacturer: "Acme",
            interfaceClass: "03",
        )

        let line = "Bus 003 Device 002: ID 1234:5678 Acme Probe"
        let parsed = try #require(USBDeviceService.parseLsusbLine(line))
        #expect(parsed.id == "bus:003.002")
        #expect(parsed.serialNumber == nil)
        let enriched = USBDeviceService.withSysfsIdentity(parsed, root: root)
        #expect(enriched.id == "0x1234:0x5678:ZX9")
        #expect(enriched.serialNumber == "ZX9")
        #expect(enriched.idUnstable == false)
        #expect(enriched.bus == 3)
        #expect(enriched.address == 2)

        try writeSysfsDevice(
            at: root.appendingPathComponent("1-4"),
            vendor: "046d",
            product: "c52b",
            bus: "1",
            address: "4",
            serial: nil,
            productName: "Receiver",
            manufacturer: "Logitech",
            interfaceClass: "03",
        )
        let listed = USBDeviceService.listSysfsDevices(root: root)
        let noSerial = listed.first { $0.bus == 1 && $0.address == 4 }
        #expect(noSerial?.id == "bus:001.004")
        #expect(noSerial?.idUnstable == true)
        let withSerial = listed.first { $0.serialNumber == "ZX9" }
        #expect(withSerial?.id == "0x1234:0x5678:ZX9")
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
            #expect(message.contains("no serial") || message.contains("Multiple USB devices"))
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

    @Test func `attach by live bus id persists serial`() throws {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: "Acme", serialNumber: "ZX9", bus: 3, address: 2,
        )
        #expect(host.id == "0x1234:0x5678:ZX9")
        let resolved = try USBPassthroughService.resolveAttachable(
            deviceId: "bus:003.002", hostDevices: [host],
        )
        #expect(resolved.id == "0x1234:0x5678:ZX9")
        let stored = USBPassthroughService.passthrough(from: resolved)
        #expect(stored.deviceId == "0x1234:0x5678:ZX9")
        let normalized = try USBPassthroughService.normalizeOne(
            USBPassthroughDevice(
                vendorId: "0x1234", productId: "0x5678", label: "Probe",
                deviceId: "bus:003.002",
            ),
            hostDevices: [host],
        )
        #expect(normalized.deviceId == "0x1234:0x5678:ZX9")
        #expect(normalized.serialNumber == "ZX9")
        let args = try QEMUBuilder.usbHostArgs(
            usb: [USBPassthroughService.workload(from: normalized)],
            hostDevices: [host],
        )
        #expect(args.contains { $0.contains("usb-host,hostbus=3,hostaddr=2") })
        #expect(!args.contains { $0.contains("vendorid=") })
    }

    @Test func `serial-less listing and vid pid attach fail closed`() {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: nil, serialNumber: nil, bus: 3, address: 2,
        )
        #expect(host.id == "bus:003.002")

        let listedErr = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.resolveAttachable(
                deviceId: host.id, hostDevices: [host],
            )
        }
        if case let .conflict(message) = listedErr {
            #expect(message.contains("no serial"))
            #expect(message.contains("cannot persist"))
            #expect(!message.contains("Re-attach"))
        } else {
            Issue.record("expected conflict, got \(String(describing: listedErr))")
        }

        let pairErr = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.resolveAttachable(
                deviceId: "0x1234:0x5678", hostDevices: [host],
            )
        }
        if case let .conflict(message) = pairErr {
            #expect(message.contains("no serial"))
            #expect(!message.contains("vendorid="))
        } else {
            Issue.record("expected conflict, got \(String(describing: pairErr))")
        }

        let stored = USBPassthroughService.passthrough(from: host)
        #expect(stored.deviceId == "bus:003.002")
        let persistErr = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.normalizeOne(stored, hostDevices: [host])
        }
        if case let .conflict(message) = persistErr {
            #expect(message.contains("no serial"))
            #expect(message.contains("cannot persist"))
        } else {
            Issue.record("expected conflict, got \(String(describing: persistErr))")
        }
    }

    @Test func `qemu args fail closed when unique pair host is missing`() {
        let usb = [WorkloadUSBDevice(vendorId: "0x1234", productId: "0x5678", label: "legacy")]
        let err = #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [])
        }
        if case let .conflict(message) = err {
            #expect(message.contains("no serial"))
            #expect(!message.contains("vendorid="))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `legacy stored bus identity is rejected on persist and qemu`() {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: nil, serialNumber: nil, bus: 3, address: 2,
        )
        let stored = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            deviceId: "bus:003.002",
        )
        let persistErr = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.normalizeOne(stored, hostDevices: [host])
        }
        if case let .conflict(message) = persistErr {
            #expect(message.contains("no serial"))
            #expect(message.contains("cannot persist"))
            #expect(!message.contains("Re-attach"))
        } else {
            Issue.record("expected conflict, got \(String(describing: persistErr))")
        }

        let usb = [
            WorkloadUSBDevice(
                vendorId: "0x1234", productId: "0x5678", label: "Probe",
                deviceId: "bus:003.002",
            ),
        ]
        let qemuErr = #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [host])
        }
        if case let .conflict(message) = qemuErr {
            #expect(message.contains("bus address"))
            #expect(!message.contains("vendorid="))
            #expect(!message.contains("hostbus="))
        } else {
            Issue.record("expected conflict, got \(String(describing: qemuErr))")
        }
    }

    @Test func `legacy stored bus identity is rejected when the live bus is gone`() {
        let stored = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            deviceId: "bus:003.002",
        )
        let gone = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.normalizeOne(stored, hostDevices: [])
        }
        if case let .notFound(message) = gone {
            #expect(message?.contains("bus:003.002") == true)
        } else {
            Issue.record("expected notFound, got \(String(describing: gone))")
        }
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
        if case let .conflict(message) = err {
            #expect(message.contains("bus address"))
            #expect(message.contains("bus:003.002"))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `qemu args fail closed when bus id is stored for excluded device`() {
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
        if case let .conflict(message) = err {
            #expect(message.contains("bus address"))
            #expect(!message.contains("vendorid="))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `legacy stored bus identity occupies the live host at that address`() {
        let stored = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            deviceId: "bus:003.002",
        )
        var vm = makeVM(usb: [stored])
        vm.name = "htpc"
        let live = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: nil, serialNumber: nil, bus: 3, address: 2,
        )
        #expect(live.id == "bus:003.002")
        #expect(USBPassthroughService.matches(stored, host: live))
        #expect(USBPassthroughService.claimedBy(host: live, vms: [vm])?.id == vm.id)
        #expect(USBPassthroughService.claimedBy(host: live, vms: [vm])?.name == "htpc")
    }

    @Test func `detach by listed bus id removes stored serial device`() {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: "Acme", serialNumber: "ZX9", bus: 3, address: 2,
        )
        let stored = USBPassthroughService.passthrough(from: host)
        #expect(stored.deviceId == "0x1234:0x5678:ZX9")
        let remaining = USBPassthroughService.removing(
            [stored],
            deviceId: "bus:003.002",
            hostDevices: [host],
        )
        #expect(remaining.isEmpty)
    }

    @Test func `detach by listed bus id is a no-op without a matching host`() {
        let stored = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        let remaining = USBPassthroughService.removing(
            [stored],
            deviceId: "bus:003.002",
            hostDevices: [],
        )
        #expect(remaining.count == 1)
        #expect(remaining.first?.deviceId == "0x1234:0x5678:ZX9")
    }

    @Test func `unrelated bus detach does not remove serial or pair devices`() {
        let serialHost = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: "Acme", serialNumber: "ZX9", bus: 3, address: 2,
        )
        let pair = USBPassthroughDevice(
            vendorId: "0x046d", productId: "0xc52b", label: "recv",
            deviceId: "0x046d:0xc52b",
        )
        let serial = USBPassthroughService.passthrough(from: serialHost)
        let remaining = USBPassthroughService.removing(
            [serial, pair],
            deviceId: "bus:009.009",
            hostDevices: [
                serialHost,
                HostUSBDevice(
                    vendorId: "0x0781", productId: "0x5567", name: "Other",
                    manufacturer: nil, serialNumber: nil, bus: 9, address: 9,
                ),
            ],
        )
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.deviceId == serial.deviceId })
        #expect(remaining.contains { $0.deviceId == pair.deviceId })
    }

    @Test func `two same vid pid without serial do not attach`() {
        let hosts = [
            HostUSBDevice(
                vendorId: "0x046d", productId: "0xc52b", name: "A",
                manufacturer: nil, serialNumber: nil, bus: 1, address: 4,
            ),
            HostUSBDevice(
                vendorId: "0x046d", productId: "0xc52b", name: "B",
                manufacturer: nil, serialNumber: nil, bus: 1, address: 5,
            ),
        ]
        #expect(hosts[0].id.hasPrefix("bus:"))
        #expect(hosts[1].id.hasPrefix("bus:"))
        let persistErr = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.normalizeOne(
                USBPassthroughDevice(vendorId: "0x046d", productId: "0xc52b", label: "recv"),
                hostDevices: hosts,
            )
        }
        if case let .conflict(message) = persistErr {
            #expect(message.contains("no serial") || message.contains("Multiple USB devices"))
        } else {
            Issue.record("expected conflict, got \(String(describing: persistErr))")
        }

        let listedErr = #expect(throws: BarkVisorError.self) {
            _ = try USBPassthroughService.resolveAttachable(
                deviceId: hosts[0].id, hostDevices: hosts,
            )
        }
        if case let .conflict(message) = listedErr {
            #expect(message.contains("no serial"))
            #expect(message.contains("cannot persist"))
        } else {
            Issue.record("expected conflict, got \(String(describing: listedErr))")
        }

        let qemuErr = #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.usbHostArgs(
                usb: [
                    WorkloadUSBDevice(
                        vendorId: "0x046d", productId: "0xc52b", label: "A",
                        deviceId: hosts[0].id,
                    ),
                    WorkloadUSBDevice(
                        vendorId: "0x046d", productId: "0xc52b", label: "B",
                        deviceId: hosts[1].id,
                    ),
                ],
                hostDevices: hosts,
            )
        }
        if case let .conflict(message) = qemuErr {
            #expect(message.contains("bus address"))
            #expect(!message.contains("vendorid="))
        } else {
            Issue.record("expected conflict, got \(String(describing: qemuErr))")
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
        serial: String?,
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
        if let serial {
            try write("serial", serial)
        }
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
        #expect(
            error?.errorDescription?.contains("no serial") == true
                || error?.errorDescription?.contains("Multiple USB devices") == true,
        )
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

    @Test func `updateVM rejects legacy bus identity`() async throws {
        let legacy = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            deviceId: "bus:003.002",
        )
        try await insertVM(id: "vm-legacy-bus", name: "legacy-bus", usb: [legacy])
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.updateVM(
                id: "vm-legacy-bus",
                params: UpdateVMParams(usbDevices: [legacy], description: "migrated"),
                db: self.dbPool,
            )
        }
        #expect(error?.code == "conflict" || error?.code == "not_found")
        #expect(
            error?.errorDescription?.contains("no serial") == true
                || error?.errorDescription?.contains("not connected") == true,
        )
        let still = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-legacy-bus") }
        #expect(still?.decodedUSBDevices.first?.deviceId == "bus:003.002")
    }

    @Test func `detachUSB fails loudly when listed bus id is not attached`() async throws {
        let stored = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        try await insertVM(id: "vm-usb-detach", name: "usb-detach", usb: [stored])
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.detachUSB(
                vmID: "vm-usb-detach",
                deviceId: "bus:009.009",
                db: self.dbPool,
            )
        }
        #expect(error?.code == "not_found" || error?.httpStatus == 404)
        let still = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-usb-detach") }
        #expect(still?.decodedUSBDevices.first?.deviceId == "0x1234:0x5678:ZX9")
    }

    @Test func `detachUSB unrelated bus id does not remove serial device`() async throws {
        let serial = USBPassthroughDevice(
            vendorId: "0x1234", productId: "0x5678", label: "Probe",
            serialNumber: "ZX9", deviceId: "0x1234:0x5678:ZX9",
        )
        let pair = USBPassthroughDevice(
            vendorId: "0x046d", productId: "0xc52b", label: "recv",
            deviceId: "0x046d:0xc52b",
        )
        try await insertVM(id: "vm-usb-two", name: "usb-two", usb: [serial, pair])
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.detachUSB(
                vmID: "vm-usb-two",
                deviceId: "bus:009.009",
                db: self.dbPool,
            )
        }
        #expect(error?.code == "not_found" || error?.httpStatus == 404)
        let still = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-usb-two") }
        let ids = still?.decodedUSBDevices.map(\.deviceId)
        #expect(ids?.contains("0x1234:0x5678:ZX9") == true)
        #expect(ids?.contains("0x046d:0xc52b") == true)
        #expect(still?.decodedUSBDevices.count == 2)
    }

    @Test func `updateVMSpec rejects unique serial-less pair`() async throws {
        let host = HostUSBDevice(
            vendorId: "0x1234", productId: "0x5678", name: "Probe",
            manufacturer: nil, serialNumber: nil, bus: 3, address: 2,
        )
        try await insertVM(id: "vm-usb-pair", name: "usb-pair", usb: nil)
        let existing = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-usb-pair") }
        let vm = try #require(existing)
        var spec = WorkloadSpecProjector.fromVM(vm)
        spec.spec.guestType = hostLinux
        spec.spec.usb = [USBPassthroughService.workload(from: USBPassthroughService.passthrough(from: host))]
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.updateVMSpec(
                id: "vm-usb-pair", spec: spec, db: self.dbPool, hostDevices: [host],
            )
        }
        #expect(error?.code == "conflict")
        let stored = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-usb-pair") }
        #expect(stored?.decodedUSBDevices.isEmpty == true)
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
