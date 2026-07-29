import Foundation

public struct QEMULaunchConfig {
    public let executable: URL
    public let arguments: [String]
    // Optional swtpm process for TPM 2.0 emulation
    public let swtpmExecutable: URL?
    public let swtpmArguments: [String]?
    public let swtpmStateDir: URL?

    public init(
        executable: URL,
        arguments: [String],
        swtpmExecutable: URL?,
        swtpmArguments: [String]?,
        swtpmStateDir: URL?,
    ) {
        self.executable = executable
        self.arguments = arguments
        self.swtpmExecutable = swtpmExecutable
        self.swtpmArguments = swtpmArguments
        self.swtpmStateDir = swtpmStateDir
    }
}

public struct QEMUBuildContext {
    public let vm: VM
    public let disk: Disk
    public let isos: [VMImage]
    public let network: Network?
    public let additionalDisks: [Disk]
    public let sockets: VMSockets
    public let bridgeSocketPath: String?

    public var vncSock: URL {
        sockets.vnc
    }
    public var serialSock: URL {
        sockets.serial
    }
    public var qmpSock: URL {
        sockets.qmp
    }

    public init(
        vm: VM,
        disk: Disk,
        isos: [VMImage],
        network: Network?,
        additionalDisks: [Disk],
        sockets: VMSockets,
        bridgeSocketPath: String?,
    ) {
        self.vm = vm
        self.disk = disk
        self.isos = isos
        self.network = network
        self.additionalDisks = additionalDisks
        self.sockets = sockets
        self.bridgeSocketPath = bridgeSocketPath
    }
}

// swiftlint:disable file_length
public enum QEMUBuilder {
    private static let arm64Types: Set<String> = ["linux-arm64", "windows-arm64"]
    private static let x86Types: Set<String> = ["linux-amd64", "linux-x86_64"]

    /// Host accelerator — single source: PlatformCapabilities (KVM if available, else TCG).
    public static var accelerator: String {
        PlatformCapabilities.accelerator
    }

    /// QEMU CPU model for the current accelerator.
    public static var cpuModel: String {
        PlatformCapabilities.qemuCPUModel
    }

    /// Machine type for the guest architecture.
    public static func machineType(for vmType: String) -> String {
        x86Types.contains(vmType) ? "q35" : "virt"
    }

    // MARK: - Input Validation

    /// Validates a port number is in range 1-65535
    public static func validatePort(_ port: Int) throws {
        guard port >= 1, port <= 65_535 else {
            throw BarkVisorError.invalidArgument("Port number out of range (1-65535): \(port)")
        }
    }

    /// Validates a port forward protocol is tcp or udp only
    public static func validateProtocol(_ proto: String) throws {
        guard proto == "tcp" || proto == "udp" else {
            throw BarkVisorError.invalidArgument("Protocol must be 'tcp' or 'udp', got: \(proto)")
        }
    }

    /// Validates a display resolution string is "NNNNxNNNN" (numeric only)
    public static func validateResolution(_ resolution: String) throws -> (String, String) {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]),
              w > 0, w <= 7_680, h > 0, h <= 4_320
        else {
            throw BarkVisorError.invalidArgument(
                "Invalid display resolution: \(resolution). Expected format: WIDTHxHEIGHT (e.g. 1280x800)",
            )
        }
        return (String(w), String(h))
    }

    /// Validates that a value interpolated into a QEMU argument does not contain commas.
    /// QEMU uses commas as key=value separators, so a comma in any interpolated field
    /// could be interpreted as a new QEMU option (argument injection).
    public static func sanitizeQEMUArg(_ value: String, label: String) throws -> String {
        guard !value.contains(",") else {
            throw BarkVisorError.invalidArgument(
                "\(label) must not contain commas (QEMU argument injection risk): \(value)",
            )
        }
        return value
    }

    /// Validates a shared path: no commas (QEMU injection), must exist, and within allowed prefixes.
    /// Home is always allowed. macOS also allows `/Volumes/`; Linux also allows `/mnt/` and `/media/`.
    public static func validateSharedPath(_ path: String) throws {
        guard !path.contains(",") else {
            throw BarkVisorError.invalidArgument("Shared path must not contain commas: \(path)")
        }
        // Resolve symlinks to prevent traversal
        let resolved = (path as NSString).resolvingSymlinksInPath
        let home = NSHomeDirectory()
        var allowedPrefixes = [home + "/"]
        #if os(macOS)
            allowedPrefixes.append("/Volumes/")
        #elseif os(Linux)
            allowedPrefixes.append(contentsOf: ["/mnt/", "/media/"])
        #endif
        guard resolved == home || allowedPrefixes.contains(where: { resolved.hasPrefix($0) }) else {
            #if os(macOS)
                let hint = "your home directory or /Volumes"
            #elseif os(Linux)
                let hint = "your home directory, /mnt, or /media"
            #else
                let hint = "your home directory"
            #endif
            throw BarkVisorError.invalidArgument(
                "Shared path must be within \(hint): \(path)",
            )
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue
        else {
            throw BarkVisorError.invalidArgument(
                "Shared path does not exist or is not a directory: \(path)",
            )
        }
    }

    /// Validates a USB vendor or product ID is in 0xHHHH hex format
    public static func validateUSBId(_ hex: String) throws {
        let pattern = #/^0x[0-9a-fA-F]{1,4}$/#
        guard hex.wholeMatch(of: pattern) != nil else {
            throw BarkVisorError.invalidArgument("Invalid USB ID: \(hex). Expected format: 0xHHHH (hex)")
        }
    }

    public static func binaryName(for vmType: String) throws -> String {
        if arm64Types.contains(vmType) {
            return "qemu-system-aarch64"
        }
        if x86Types.contains(vmType) {
            return "qemu-system-x86_64"
        }
        throw BarkVisorError.unknownVMType(vmType)
    }

    public static func binary(for vmType: String) throws -> URL {
        try resolveQEMU(binaryName(for: vmType))
    }

    public static func launchConfig(ctx: QEMUBuildContext) throws -> QEMULaunchConfig {
        let vm = ctx.vm
        let disk = ctx.disk
        let qemuBinary = try binary(for: vm.vmType)

        _ = try sanitizeQEMUArg(disk.path, label: "Disk path")
        _ = try sanitizeQEMUArg(disk.format, label: "Disk format")

        guard arm64Types.contains(vm.vmType) || x86Types.contains(vm.vmType) else {
            throw BarkVisorError.unknownVMType(vm.vmType)
        }

        let windows = vm.vmType.hasPrefix("windows")
        let bootOrder = vm.bootOrder ?? "cd"
        let diskFirst = bootOrder.first == "c"
        let machine = machineType(for: vm.vmType)

        var args: [String] = []
        args += ["-machine", machine, "-accel", accelerator, "-cpu", cpuModel]
        args += ["-smp", "\(vm.cpuCount)", "-m", "\(vm.memoryMb)M"]
        args += try firmwareArgs(vmID: vm.id, vmType: vm.vmType)
        args += ["-device", "qemu-xhci"]
        args += bootDiskArgs(disk: disk, windows: windows, diskFirst: diskFirst)
        args += try isoArgs(isos: ctx.isos, windows: windows, diskFirst: diskFirst)
        args += try cloudInitArgs(vm: vm)
        args += try sharedFolderArgs(vm: vm)
        let tpm = try tpmArgs(vm: vm)
        args += tpm.args
        args += try additionalDiskArgs(ctx.additionalDisks)
        let (netArgs, needsSocketVmnetWrap) = try networkArgs(vm: vm, network: ctx.network)
        args += netArgs
        args += socketArgs(ctx: ctx)
        args += displayAndInputArgs(vm: vm)
        args += try usbPassthroughArgs(vm: vm)
        args += try miscArgs(vm: vm)

        // socket_vmnet wrap is macOS-only (not the same as "bridged networking is in use").
        if needsSocketVmnetWrap {
            #if os(macOS)
                let (clientBin, socketPath) = try resolveSocketVmnet(
                    bridgeInterface: ctx.network?.bridge, dbSocketPath: ctx.bridgeSocketPath,
                )
                let wrappedArgs = [socketPath, qemuBinary.path] + args
                return QEMULaunchConfig(
                    executable: clientBin, arguments: wrappedArgs,
                    swtpmExecutable: tpm.exe, swtpmArguments: tpm.swtpmArgs, swtpmStateDir: tpm.dir,
                )
            #else
                // Linux bridged path sets needsSocketVmnetWrap = false (-netdev bridge).
                throw BarkVisorError.badRequest(
                    "socket_vmnet wrapping is only available on macOS.",
                )
            #endif
        }

        return QEMULaunchConfig(
            executable: qemuBinary, arguments: args,
            swtpmExecutable: tpm.exe, swtpmArguments: tpm.swtpmArgs, swtpmStateDir: tpm.dir,
        )
    }

    // MARK: - Argument Builders

    private static func firmwareArgs(vmID: String, vmType: String) throws -> [String] {
        let (codeImage, varsImage) = try prepareFirmware(vmID: vmID, vmType: vmType)
        return [
            "-drive", "if=pflash,format=raw,readonly=on,file=\(codeImage.path)",
            "-drive", "if=pflash,format=raw,file=\(varsImage.path)",
        ]
    }

    private static func bootDiskArgs(disk: Disk, windows: Bool, diskFirst: Bool) -> [String] {
        let diskBootIndex = diskFirst ? 0 : 1
        let driveArgs = [
            "-drive", "file=\(disk.path),format=\(disk.format),if=none,id=boot0,cache=writeback",
        ]
        let deviceType = windows ? "nvme,drive=boot0,serial=boot" : "virtio-blk-pci,drive=boot0"
        return driveArgs + ["-device", "\(deviceType),bootindex=\(diskBootIndex)"]
    }

    private static func isoArgs(isos: [VMImage], windows: Bool, diskFirst: Bool) throws -> [String] {
        var args: [String] = []
        for (i, iso) in isos.enumerated() {
            guard let isoPath = iso.path else { continue }
            let sanitizedISOPath = try sanitizeQEMUArg(isoPath, label: "ISO path")
            let driveId = "cdrom\(i)"
            args += [
                "-drive",
                "file=\(sanitizedISOPath),format=raw,if=none,id=\(driveId),readonly=on,media=cdrom",
            ]
            if i == 0 {
                let isoBootIndex = diskFirst ? 1 : 0
                let deviceType = windows ? "usb-storage" : "virtio-blk-pci"
                args += ["-device", "\(deviceType),drive=\(driveId),bootindex=\(isoBootIndex)"]
            } else {
                args += ["-device", "usb-storage,drive=\(driveId)"]
            }
        }
        return args
    }

    private static func cloudInitArgs(vm: VM) throws -> [String] {
        guard let ciPath = vm.cloudInitPath else { return [] }
        let sanitizedCIPath = try sanitizeQEMUArg(ciPath, label: "Cloud-init ISO path")
        return ["-drive", "file=\(sanitizedCIPath),format=raw,if=virtio,readonly=on,media=cdrom"]
    }

    private static func sharedFolderArgs(vm: VM) throws -> [String] {
        let paths = vm.decodedSharedPaths
        guard !paths.isEmpty else { return [] }
        var args: [String] = []
        for (i, path) in paths.enumerated() {
            try validateSharedPath(path)
            let tag = i == 0 ? "hostshare" : "hostshare\(i)"
            args += ["-fsdev", "local,id=shared\(i),path=\(path),security_model=mapped-xattr"]
            args += ["-device", "virtio-9p-pci,fsdev=shared\(i),mount_tag=\(tag)"]
        }
        return args
    }

    private static func tpmArgs(vm: VM) throws
        -> (args: [String], exe: URL?, swtpmArgs: [String]?, dir: URL?) {
        guard vm.tpmEnabled else { return ([], nil, nil, nil) }
        let tpmStateDir = Config.dataDir.appendingPathComponent("tpm/\(vm.id)")
        try FileManager.default.createDirectory(at: tpmStateDir, withIntermediateDirectories: true)
        let tpmSock = tpmStateDir.appendingPathComponent("swtpm.sock")
        let exe = try resolveSwtpm()
        let swtpmArgs = [
            "socket",
            "--tpmstate", "dir=\(tpmStateDir.path)",
            "--ctrl", "type=unixio,path=\(tpmSock.path)",
            "--tpm2",
            "--log", "level=20",
        ]
        // aarch64 uses tpm-tis-device; x86_64 uses tpm-tis.
        let tpmDevice = x86Types.contains(vm.vmType) ? "tpm-tis,tpmdev=tpm0" : "tpm-tis-device,tpmdev=tpm0"
        let args = [
            "-chardev", "socket,id=chrtpm,path=\(tpmSock.path)",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
            "-device", tpmDevice,
        ]
        return (args, exe, swtpmArgs, tpmStateDir)
    }

    private static func additionalDiskArgs(_ disks: [Disk]) throws -> [String] {
        var args: [String] = []
        for (i, extraDisk) in disks.enumerated() {
            let sanitizedPath = try sanitizeQEMUArg(extraDisk.path, label: "Additional disk path")
            let sanitizedFormat = try sanitizeQEMUArg(extraDisk.format, label: "Additional disk format")
            args += [
                "-drive",
                "file=\(sanitizedPath),format=\(sanitizedFormat),if=virtio,cache=writeback,id=extra\(i)",
            ]
        }
        return args
    }

    private static func networkArgs(vm: VM, network: Network?) throws
        -> (args: [String], needsSocketVmnetWrap: Bool) {
        var netdevArgs = ""
        var deviceArgs = "virtio-net-pci,netdev=net0"
        // True only when QEMU must be exec'd under socket_vmnet_client (macOS bridged).
        var needsSocketVmnetWrap = false

        if let mac = vm.macAddress, !mac.isEmpty {
            try validateMAC(mac)
            deviceArgs += ",mac=\(mac)"
        }

        if let net = network {
            if net.mode == "bridged" {
                #if os(macOS)
                    // socket_vmnet injects a pre-opened AF_VSOCK/unix fd as netdev fd=3.
                    netdevArgs = "socket,id=net0,fd=3"
                    needsSocketVmnetWrap = true
                #elseif os(Linux)
                    // QEMU native bridge: attaches via qemu-bridge-helper to host bridge
                    // named in network.bridge (e.g. br0). No socket_vmnet wrap.
                    let br = net.bridge ?? ""
                    guard !br.isEmpty else {
                        throw BarkVisorError.badRequest(
                            "Bridged network is missing host bridge interface name.",
                        )
                    }
                    try validateBridgeName(br)
                    let safeBr = try sanitizeQEMUArg(br, label: "Bridge interface")
                    netdevArgs = "bridge,id=net0,br=\(safeBr)"
                    needsSocketVmnetWrap = false
                #else
                    throw BarkVisorError.badRequest(
                        PlatformCapabilities.unsupportedMessage(.bridgedNetworking),
                    )
                #endif
            } else {
                netdevArgs = "user,id=net0"
                if let dns = net.dnsServer, !dns.isEmpty {
                    try validateIPv4(dns)
                    netdevArgs += ",dns=\(dns)"
                }
                for rule in vm.decodedPortForwards {
                    try validateProtocol(rule.protocol)
                    try validatePort(rule.hostPort)
                    try validatePort(rule.guestPort)
                    netdevArgs += ",hostfwd=\(rule.protocol)::\(rule.hostPort)-:\(rule.guestPort)"
                }
            }
        } else {
            netdevArgs = "user,id=net0"
        }

        return (["-netdev", netdevArgs, "-device", deviceArgs], needsSocketVmnetWrap)
    }

    private static func socketArgs(ctx: QEMUBuildContext) -> [String] {
        let s = ctx.sockets
        return [
            "-chardev", "socket,id=serial0,path=\(s.serial.path),server=on,wait=off",
            "-serial", "chardev:serial0",
            "-vnc", "unix:\(s.vnc.path)",
            "-qmp", "unix:\(s.qmp.path),server,nowait",
            "-qmp", "unix:\(s.event.path),server,nowait",
            "-device", "virtio-serial-pci",
            "-chardev", "socket,path=\(s.guestAgent.path),server=on,wait=off,id=qga0",
            "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
        ]
    }

    private static func displayAndInputArgs(vm: VM) -> [String] {
        let resolution = vm.displayResolution ?? "1280x800"
        var args = ["-device", "ramfb"]
        if let (w, h) = try? validateResolution(resolution) {
            args += ["-device", "virtio-gpu-pci,xres=\(w),yres=\(h)"]
        } else {
            args += ["-device", "virtio-gpu-pci"]
        }
        return args + ["-device", "usb-kbd", "-device", "usb-tablet"]
    }

    private static func usbPassthroughArgs(vm: VM) throws -> [String] {
        let usbDevs = vm.decodedUSBDevices
        guard !usbDevs.isEmpty else { return [] }
        var args: [String] = []
        for (i, dev) in usbDevs.enumerated() {
            try validateUSBId(dev.vendorId)
            try validateUSBId(dev.productId)
            args += [
                "-device",
                "usb-host,vendorid=\(dev.vendorId),productid=\(dev.productId),guest-reset=off,id=usb-pt-\(i)",
            ]
        }
        return args
    }

    private static func miscArgs(vm: VM) throws -> [String] {
        let sanitizedName = try sanitizeQEMUArg(vm.name, label: "VM name")
        var args: [String] = [
            "-device", "virtio-balloon-pci",
            "-device", "virtio-rng-pci",
            "-name", sanitizedName, "-uuid", vm.id,
        ]
        if let dataDir = BundleResolver.qemuDataDir() {
            args += ["-L", dataDir.path]
        }
        args += ["-display", "none"]
        return args
    }

    // MARK: - Firmware

    private static func prepareFirmware(vmID: String, vmType: String) throws -> (code: URL, vars: URL) {
        let fwDir = Config.dataDir.appendingPathComponent("efivars/\(vmID)")
        try FileManager.default.createDirectory(at: fwDir, withIntermediateDirectories: true)
        let varsFile = fwDir.appendingPathComponent("vars.fd")

        switch vmType {
        case "windows-arm64":
            // Windows ARM64 needs AAVMF secure boot firmware (extracted from Ubuntu qemu-efi-aarch64 package)
            let codeFile = try resolveAAVMFSecureBoot()
            if !FileManager.default.fileExists(atPath: varsFile.path) {
                FileManager.default.createFile(atPath: varsFile.path, contents: Data(count: 67_108_864))
            }
            return (codeFile, varsFile)
        case "linux-arm64":
            let codeFile = try resolveEDK2ARM64()
            if !FileManager.default.fileExists(atPath: varsFile.path) {
                FileManager.default.createFile(atPath: varsFile.path, contents: Data(count: 67_108_864))
            }
            return (codeFile, varsFile)
        case "linux-amd64", "linux-x86_64":
            let codeFile = try resolveEDK2X86_64()
            if !FileManager.default.fileExists(atPath: varsFile.path) {
                // OVMF vars is typically 540 KiB; allocate a generous blank file.
                FileManager.default.createFile(atPath: varsFile.path, contents: Data(count: 540_672))
            }
            return (codeFile, varsFile)
        default:
            throw BarkVisorError.unknownVMType(vmType)
        }
    }

    // MARK: - socket_vmnet resolution

    public static func resolveSocketVmnet(bridgeInterface: String?, dbSocketPath: String? = nil)
        throws -> (client: URL, socketPath: String) {
        #if os(macOS)
            let clientBin = try BundleResolver.optHelper(
                "socket_vmnet_client",
                package: "socket_vmnet",
                extraPaths: ["/opt/socket_vmnet/bin/socket_vmnet_client"],
            )

            // Prefer socket path from DB (kept current by bridge helper)
            if let dbPath = dbSocketPath, FileManager.default.fileExists(atPath: dbPath) {
                return (clientBin, dbPath)
            }

            // Fallback: scan filesystem for socket (backward compat)
            let iface = bridgeInterface ?? "en0"
            let socketCandidates = [
                "/opt/homebrew/var/run/socket_vmnet.bridged.\(iface)",
                "/var/run/socket_vmnet.bridged.\(iface)",
                "/opt/homebrew/var/run/socket_vmnet",
                "/var/run/socket_vmnet",
            ]

            guard let socketPath = socketCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
            else {
                throw BarkVisorError.processSpawnFailed(
                    "socket_vmnet daemon socket not found. For bridged networking run:\n"
                        + "sudo brew services start socket_vmnet\n"
                        + "For true bridged mode on \(iface), see: https://github.com/lima-vm/socket_vmnet",
                )
            }

            return (clientBin, socketPath)
        #else
            throw BarkVisorError.badRequest(
                PlatformCapabilities.unsupportedMessage(.managedBridgeDaemon),
            )
        #endif
    }

    // MARK: - Binary resolution

    private static func resolveQEMU(_ name: String) throws -> URL {
        do {
            return try BundleResolver.helper(name)
        } catch {
            throw BarkVisorError.qemuNotFound(
                "\(name) not found. Install QEMU via: \(PlatformQEMU.qemuInstallHint)",
            )
        }
    }

    private static func resolveEDK2ARM64() throws -> URL {
        // Homebrew / bundled name, then distro firmware tables
        if let url = BundleResolver.qemuResource("edk2-aarch64-code.fd") {
            return url
        }
        if let found = PlatformQEMU.edk2ARM64Candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) {
            return URL(fileURLWithPath: found)
        }
        throw BarkVisorError.firmwareNotFound(
            "ARM64 UEFI firmware not found (edk2-aarch64-code.fd / AAVMF_CODE.fd). Install via: \(PlatformQEMU.firmwareInstallHintARM64)",
        )
    }

    private static func resolveEDK2X86_64() throws -> URL {
        // Homebrew ships edk2-x86_64-code.fd; Linux packages often use OVMF_CODE.fd.
        if let url = BundleResolver.qemuResource("edk2-x86_64-code.fd") {
            return url
        }
        if let url = BundleResolver.qemuResource("OVMF_CODE.fd") {
            return url
        }
        if let found = PlatformQEMU.edk2X86Candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) {
            return URL(fileURLWithPath: found)
        }
        throw BarkVisorError.firmwareNotFound(
            "x86_64 UEFI firmware (edk2-x86_64-code.fd / OVMF) not found. Install via: \(PlatformQEMU.firmwareInstallHintX86)",
        )
    }

    private static func resolveAAVMFSecureBoot() throws -> URL {
        // Bundled / Homebrew share via BundleResolver, then distro AAVMF paths
        if let url = BundleResolver.qemuResource("AAVMF_CODE.secboot.fd") {
            return url
        }
        if let found = PlatformQEMU.aavmfSecureBootCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) {
            return URL(fileURLWithPath: found)
        }
        throw BarkVisorError.firmwareNotFound(
            "AAVMF secure-boot firmware not found. \(PlatformQEMU.aavmfSecureBootInstallHint)",
        )
    }

    private static func resolveSwtpm() throws -> URL {
        do {
            return try BundleResolver.helper("swtpm")
        } catch {
            throw BarkVisorError.processSpawnFailed(
                "swtpm not found. TPM 2.0 emulation requires swtpm.\nInstall via: \(PlatformQEMU.swtpmInstallHint)",
            )
        }
    }
}
// swiftlint:enable file_length
