import Foundation

extension VMLifecycleService {
    struct EncodedUpdateFields {
        let sharedPathsJSON: String?
        let diskIdsJSON: String?
        let portForwardsJSON: String?
        let usbDevicesJSON: String?
        let gpuDevicesJSON: String?
    }

    static func encodeUpdateFields(params: UpdateVMParams) -> EncodedUpdateFields {
        let sharedPathsJSON: String? =
            if let paths = params.sharedPaths {
                paths.isEmpty ? nil : JSONColumnCoding.encode(paths)
            } else { nil as String? }
        let diskIdsJSON: String? =
            if let diskIds = params.additionalDiskIds {
                JSONColumnCoding.encode(diskIds)
            } else { nil as String? }
        let portForwardsJSON: String? =
            if let pf = params.portForwards {
                pf.isEmpty ? nil : JSONColumnCoding.encode(pf)
            } else { nil as String? }
        let usbDevicesJSON: String? =
            if let usb = params.usbDevices {
                usb.isEmpty ? nil : JSONColumnCoding.encode(usb)
            } else { nil as String? }
        let gpuDevicesJSON: String? =
            if let gpu = params.gpuDevices {
                gpu.isEmpty ? nil : JSONColumnCoding.encode(gpu)
            } else { nil as String? }
        return EncodedUpdateFields(
            sharedPathsJSON: sharedPathsJSON, diskIdsJSON: diskIdsJSON,
            portForwardsJSON: portForwardsJSON, usbDevicesJSON: usbDevicesJSON,
            gpuDevicesJSON: gpuDevicesJSON,
        )
    }

    static func detectHardwareChanges(
        params: UpdateVMParams,
        encoded: EncodedUpdateFields,
        vm: VM,
    ) -> Bool {
        if params.cpuCount != nil, params.cpuCount != vm.cpuCount { return true }
        if params.memoryMB != nil, params.memoryMB != vm.memoryMb { return true }
        if params.networkId != nil, params.networkId != vm.networkId { return true }
        if params.displayResolution != nil, params.displayResolution != vm.displayResolution {
            return true
        }
        if params.bootOrder != nil, params.bootOrder != vm.bootOrder { return true }
        if params.uefi != nil, params.uefi != vm.uefi { return true }
        if params.tpmEnabled != nil, params.tpmEnabled != vm.tpmEnabled { return true }
        if params.sharedPaths != nil { return true }
        if params.additionalDiskIds != nil { return true }
        if params.usbDevices != nil { return true }
        if params.gpuDevices != nil { return true }
        if params.portForwards != nil, encoded.portForwardsJSON != vm.portForwards { return true }
        if params.workloadClass != nil, params.workloadClass != vm.workloadClass { return true }
        return false
    }

    /// Hardware columns that require a restart when changed on a running VM.
    /// Matches `detectHardwareChanges(params:encoded:vm:)` plus spec-only fields
    /// (`vmType`, ISO attachments, MAC, cloud-init ISO, overrides) that apply()
    /// can rewrite. Overrides stay out of flat hardware columns, but they change
    /// resolved QEMU launch values (CPU, memory, accelerator, hugepages).
    static func detectHardwareChanges(before: VM, after: VM) -> Bool {
        if before.cpuCount != after.cpuCount { return true }
        if before.memoryMb != after.memoryMb { return true }
        if before.networkId != after.networkId { return true }
        if before.displayResolution != after.displayResolution { return true }
        if before.bootOrder != after.bootOrder { return true }
        if before.uefi != after.uefi { return true }
        if before.tpmEnabled != after.tpmEnabled { return true }
        if before.decodedSharedPaths != after.decodedSharedPaths { return true }
        if before.decodedAdditionalDiskIds != after.decodedAdditionalDiskIds { return true }
        if before.decodedUSBDevices != after.decodedUSBDevices { return true }
        if before.decodedGPUDevices != after.decodedGPUDevices { return true }
        if before.decodedPortForwards != after.decodedPortForwards { return true }
        if before.vmType != after.vmType { return true }
        if before.decodedISOIds != after.decodedISOIds { return true }
        if before.macAddress != after.macAddress { return true }
        if before.cloudInitPath != after.cloudInitPath { return true }
        if before.decodedOverrides != after.decodedOverrides { return true }
        if before.workloadClass != after.workloadClass { return true }
        return false
    }

    static func applyUpdates(
        params: UpdateVMParams,
        encoded: EncodedUpdateFields,
        to vm: inout VM,
    ) {
        if let name = params.name { vm.name = name }
        if let cpu = params.cpuCount { vm.cpuCount = cpu }
        if let mem = params.memoryMB { vm.memoryMb = mem }
        if let net = params.networkId { vm.networkId = net }
        if let desc = params.description { vm.description = desc }
        if let boot = params.bootOrder { vm.bootOrder = boot }
        if let res = params.displayResolution { vm.displayResolution = res }
        if let uefi = params.uefi { vm.uefi = uefi }
        if let tpm = params.tpmEnabled { vm.tpmEnabled = tpm }
        if params.sharedPaths != nil { vm.sharedPaths = encoded.sharedPathsJSON }
        if params.additionalDiskIds != nil { vm.additionalDiskIds = encoded.diskIdsJSON }
        if params.usbDevices != nil { vm.usbDevices = encoded.usbDevicesJSON }
        if params.gpuDevices != nil { vm.gpuDevices = encoded.gpuDevicesJSON }
        if params.portForwards != nil { vm.portForwards = encoded.portForwardsJSON }
        if let klass = params.workloadClass {
            vm.workloadClass = (try? WorkloadClass.parse(klass).rawValue) ?? vm.workloadClass
        }
    }
}
