import Foundation
import Testing
@testable import BarkVisorCore

@Suite("QEMU device support", .serialized)
struct QEMUDeviceSupportTests {
    @Test func `parses device help output`() {
        let text = """
        Controller devices:
          name "pci-ohci", bus PCI, desc ""
          name "qemu-xhci", bus PCI
        USB devices:
          name "usb-kbd", bus usb-bus
          name "usb-tablet", bus usb-bus
        Generic devices:
          name "virtio-gpu-pci", bus PCI, alias "virtio-gpu"
          name "ramfb", bus System
        """
        let names = QEMUDeviceSupport.parseDeviceNames(text)
        #expect(names?.contains("virtio-gpu-pci") == true)
        #expect(names?.contains("qemu-xhci") == true)
        #expect(names?.contains("ramfb") == true)
    }

    @Test func `unparseable output yields no device set`() {
        #expect(QEMUDeviceSupport.parseDeviceNames("qemu-system-x86_64: error: unknown option") == nil)
        #expect(QEMUDeviceSupport.parseDeviceNames("") == nil)
    }

    @Test func `missing modules are detected against required launch devices`() {
        let supported = [
            "qemu-xhci", "ramfb", "usb-kbd", "usb-tablet",
            "virtio-net-pci", "virtio-serial-pci", "virtio-blk-pci",
        ]
        let missing = QEMUDeviceSupport.requiredLaunchDevices.subtracting(supported).sorted()
        #expect(missing == ["virtio-gpu-pci"])

        var windowsRequired = QEMUDeviceSupport.requiredLaunchDevices
        windowsRequired.formUnion(QEMUDeviceSupport.requiredWindowsDevices)
        #expect(windowsRequired.subtracting(supported).sorted() == ["nvme", "usb-storage", "virtio-gpu-pci"])
    }

    @Test func `firmware vars candidates match the 4m token case-insensitively`() {
        let candidates = [
            "/usr/share/OVMF/OVMF_VARS.fd",
            "/usr/share/edk2/x64/OVMF_VARS.4m.fd",
            "/usr/share/OVMF/OVMF_VARS_4M.fd",
        ]
        let codePath = "/usr/share/edk2/x64/OVMF_CODE.4m.fd"
        let ordered = QEMUBuilder.preferMatchingFirmwareToken("4M", in: candidates, codePath: codePath)
        #expect(ordered.first == "/usr/share/edk2/x64/OVMF_VARS.4m.fd")
        #expect(ordered.last == "/usr/share/OVMF/OVMF_VARS.fd")
    }

    @Test func `secboot token still reorders`() {
        let candidates = [
            "/usr/share/OVMF/OVMF_VARS_4M.fd",
            "/usr/share/OVMF/OVMF_VARS.secboot.fd",
        ]
        let ordered = QEMUBuilder.preferMatchingFirmwareToken(
            "secboot",
            in: candidates,
            codePath: "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd",
        )
        #expect(ordered.first == "/usr/share/OVMF/OVMF_VARS.secboot.fd")
    }
}
