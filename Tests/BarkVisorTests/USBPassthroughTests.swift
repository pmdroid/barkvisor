import Foundation
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

    @Test func `qemu args keep vendor product for legacy attachments`() throws {
        let usb = [WorkloadUSBDevice(vendorId: "0x1234", productId: "0x5678", label: "legacy")]
        let args = try QEMUBuilder.usbHostArgs(usb: usb, hostDevices: [])
        #expect(args.contains { $0.contains("vendorid=0x1234,productid=0x5678") })
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
