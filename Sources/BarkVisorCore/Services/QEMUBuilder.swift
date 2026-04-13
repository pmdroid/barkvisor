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
    public let vncSock: URL
    public let monitorSock: URL
    public let serialSock: URL
    public let qmpSock: URL
    public let bridgeSocketPath: String?
}

// swiftlint:disable file_length
public enum QEMUBuilder {
    private static var isARM64: Set<String> {
        ["linux-arm64", "windows-arm64"]
    }

    // MARK: - Input Validation

    /// Validates an IPv4 address (digits and dots only, four octets 0-255)
    public static func validateIPv4(_ ip: String) throws {
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  guard let n = UInt16(part), n <= 255 else { return false }
                  return part == String(n) // reject leading zeros
              })
        else {
            throw BarkVisorError.invalidArgument("Invalid IPv4 address: \(ip)")
        }
    }

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

    /// Validates a shared path: no commas (QEMU injection), must exist, and within home or /Volumes
    public static func validateSharedPath(_ path: String) throws {
        guard !path.contains(",") else {
            throw BarkVisorError.invalidArgument("Shared path must not contain commas: \(path)")
        }
        // Resolve symlinks to prevent traversal
        let resolved = (path as NSString).resolvingSymlinksInPath
        let home = NSHomeDirectory()
        let allowedPrefixes = [home + "/", "/Volumes/"]
        guard resolved == home || allowedPrefixes.contains(where: { resolved.hasPrefix($0) }) else {
            throw BarkVisorError.invalidArgument(
                "Shared path must be within your home directory or /Volumes: \(path)",
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

    /// Validates a MAC address matches the expected format (XX:XX:XX:XX:XX:XX, hex only)
    public static func validateMAC(_ mac: String) throws {
        let parts = mac.split(separator: ":")
        guard parts.count == 6,
              parts.allSatisfy({ part in
                  part.count == 2 && part.allSatisfy(\.isHexDigit)
              })
        else {
            throw BarkVisorError.invalidArgument("Invalid MAC address: \(mac)")
        }
    }

    public static func binary(for vmType: String) throws -> URL {
        guard isARM64.contains(vmType) else {
            throw BarkVisorError.unknownVMType(vmType)
        }
        return try resolveQEMU("qemu-system-aarch64")
    }

    public static func launchConfig(ctx: QEMUBuildContext) throws -> QEMULaunchConfig {
        let vm = ctx.vm
        let disk = ctx.disk
        let qemuBinary = try binary(for: vm.vmType)

        _ = try sanitizeQEMUArg(disk.path, label: "Disk path")
        _ = try sanitizeQEMUArg(disk.format, label: "Disk format")

        guard isARM64.contains(vm.vmType) else {
            throw BarkVisorError.unknownVMType(vm.vmType)
        }

        let windows = vm.vmType.hasPrefix("windows")
        let bootOrder = vm.bootOrder ?? "cd"
        let diskFirst = bootOrder.first == "c"

        var args: [String] = []
        args += ["-machine", "virt", "-accel", "hvf", "-cpu", "host"]
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
        let (netArgs, useBridged) = try networkArgs(vm: vm, network: ctx.network)
        args += netArgs
        args += socketArgs(ctx: ctx)
        args += displayAndInputArgs(vm: vm)
        args += try usbPassthroughArgs(vm: vm)
        args += try miscArgs(vm: vm)

        if useBridged {
            let (clientBin, socketPath) = try resolveSocketVmnet(
                bridgeInterface: ctx.network?.bridge, dbSocketPath: ctx.bridgeSocketPath,
            )
            let wrappedArgs = [socketPath, qemuBinary.path] + args
            return QEMULaunchConfig(
                executable: clientBin, arguments: wrappedArgs,
                swtpmExecutable: tpm.exe, swtpmArguments: tpm.swtpmArgs, swtpmStateDir: tpm.dir,
            )
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
        guard let json = vm.sharedPaths,
              let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
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
        let args = [
            "-chardev", "socket,id=chrtpm,path=\(tpmSock.path)",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
            "-device", "tpm-tis-device,tpmdev=tpm0",
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
        -> (args: [String], useBridged: Bool) {
        var netdevArgs = ""
        var deviceArgs = "virtio-net-pci,netdev=net0"
        var useBridged = false

        if let mac = vm.macAddress, !mac.isEmpty {
            try validateMAC(mac)
            deviceArgs += ",mac=\(mac)"
        }

        if let net = network {
            if net.mode == "bridged" {
                netdevArgs = "socket,id=net0,fd=3"
                useBridged = true
            } else {
                netdevArgs = "user,id=net0"
                if let dns = net.dnsServer, !dns.isEmpty {
                    try validateIPv4(dns)
                    netdevArgs += ",dns=\(dns)"
                }
                if let pfJSON = vm.portForwards,
                   let pfData = pfJSON.data(using: .utf8),
                   let rules = try? JSONDecoder().decode([PortForwardRule].self, from: pfData) {
                    for rule in rules {
                        try validateProtocol(rule.protocol)
                        try validatePort(rule.hostPort)
                        try validatePort(rule.guestPort)
                        netdevArgs += ",hostfwd=\(rule.protocol)::\(rule.hostPort)-:\(rule.guestPort)"
                    }
                }
            }
        } else {
            netdevArgs = "user,id=net0"
        }

        return (["-netdev", netdevArgs, "-device", deviceArgs], useBridged)
    }

    private static func socketArgs(ctx: QEMUBuildContext) -> [String] {
        let evtSockPath = ctx.qmpSock.path.replacingOccurrences(of: "-qmp.sock", with: "-evt.sock")
        let vmPrefix = ctx.qmpSock.lastPathComponent.replacingOccurrences(of: "-qmp.sock", with: "")
        let gaSockPath = ctx.qmpSock.deletingLastPathComponent()
            .appendingPathComponent("\(vmPrefix)-ga.sock").path
        return [
            "-chardev", "socket,id=serial0,path=\(ctx.serialSock.path),server=on,wait=off",
            "-serial", "chardev:serial0",
            "-vnc", "unix:\(ctx.vncSock.path)",
            "-monitor", "unix:\(ctx.monitorSock.path),server,nowait",
            "-qmp", "unix:\(ctx.qmpSock.path),server,nowait",
            "-qmp", "unix:\(evtSockPath),server,nowait",
            "-device", "virtio-serial-pci",
            "-chardev", "socket,path=\(gaSockPath),server=on,wait=off,id=qga0",
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
        guard let json = vm.usbDevices,
              let data = json.data(using: .utf8),
              let usbDevs = try? JSONDecoder().decode([USBPassthroughDevice].self, from: data)
        else { return [] }
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
        default:
            throw BarkVisorError.unknownVMType(vmType)
        }
    }

    // MARK: - socket_vmnet resolution

    public static func resolveSocketVmnet(bridgeInterface: String?, dbSocketPath: String? = nil)
        throws -> (client: URL, socketPath: String) {
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
    }

    // MARK: - Binary resolution

    private static func resolveQEMU(_ name: String) throws -> URL {
        do {
            return try BundleResolver.helper(name)
        } catch {
            throw BarkVisorError.qemuNotFound("\(name) not found. Install QEMU via: brew install qemu")
        }
    }

    private static func resolveEDK2ARM64() throws -> URL {
        guard let url = BundleResolver.qemuResource("edk2-aarch64-code.fd") else {
            throw BarkVisorError.firmwareNotFound(
                "edk2-aarch64-code.fd not found. Install via: brew install qemu",
            )
        }
        return url
    }

    private static func resolveAAVMFSecureBoot() throws -> URL {
        // Bundled by build-release.sh into the QEMU share directory
        let bundledPath = URL(fileURLWithPath: Config.qemuShareDir)
            .appendingPathComponent("AAVMF_CODE.secboot.fd")

        guard FileManager.default.fileExists(atPath: bundledPath.path) else {
            throw BarkVisorError.firmwareNotFound(
                "AAVMF_CODE.secboot.fd not found at \(bundledPath.path). "
                    + "Reinstall BarkVisor or run scripts/build-release.sh to bundle firmware.",
            )
        }

        return bundledPath
    }

    private static func resolveSwtpm() throws -> URL {
        do {
            return try BundleResolver.helper("swtpm")
        } catch {
            throw BarkVisorError.processSpawnFailed(
                "swtpm not found. TPM 2.0 emulation requires swtpm.\n" + "Install via: brew install swtpm",
            )
        }
    }
}
// swiftlint:enable file_length
