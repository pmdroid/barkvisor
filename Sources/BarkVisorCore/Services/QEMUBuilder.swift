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

public struct QEMULoopbackForward: Equatable, Sendable {
    public let hostPort: Int
    public let guestPort: Int

    public init(hostPort: Int, guestPort: Int) {
        self.hostPort = hostPort
        self.guestPort = guestPort
    }
}

public struct QEMUBuildContext {
    public let vm: VM
    /// Canonical launch input. QEMUBuilder reads hardware only from this spec.
    public let spec: WorkloadSpec
    public let disk: Disk
    public let isos: [VMImage]
    public let network: Network?
    public let additionalDisks: [Disk]
    public let sockets: VMSockets
    public let bridgeSocketPath: String?
    /// Coding Agent ttyd (PAS-272). Loopback-only; not spec.portForwards.
    public let loopbackHostfwds: [QEMULoopbackForward]

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
        spec: WorkloadSpec? = nil,
        loopbackHostfwds: [QEMULoopbackForward] = [],
    ) {
        self.vm = vm
        self.spec = spec ?? WorkloadSpecProjector.fromVM(vm)
        self.disk = disk
        self.isos = isos
        self.network = network
        self.additionalDisks = additionalDisks
        self.sockets = sockets
        self.bridgeSocketPath = bridgeSocketPath
        self.loopbackHostfwds = loopbackHostfwds
    }
}

// swiftlint:disable file_length
public enum QEMUBuilder {
    /// Host accelerator — single source: PlatformCapabilities (KVM if available, else TCG).
    public static var accelerator: String {
        PlatformCapabilities.accelerator
    }

    /// QEMU CPU model for the current accelerator.
    public static var cpuModel: String {
        cpuModel(for: accelerator)
    }

    public static func cpuModel(for accelerator: String) -> String {
        WorkloadSpecResolver.cpuModel(for: accelerator)
    }

    static func hugepagesArgs(
        hugepagesPath: String = "/dev/hugepages",
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) throws -> [String] {
        guard fileExists(hugepagesPath) else {
            throw BarkVisorError.badRequest(
                "overrides.linux.hugepages is not available: \(hugepagesPath) is missing",
            )
        }
        let path = try sanitizeQEMUArg(hugepagesPath, label: "hugepages path")
        return ["-mem-prealloc", "-mem-path", path]
    }

    /// Machine type for the guest architecture (from `GuestProfiles`).
    public static func machineType(for vmType: String) -> String {
        (try? GuestProfiles.require(vmType).machine) ?? "virt"
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

    /// `-machine` must be a known GuestProfiles type with no comma properties.
    /// When `guestType` is set, the value must match that profile's machine
    /// (`virt` on ARM, `q35` on x86) — QEMU rejects the other type at start.
    public static func validateMachine(
        _ value: String,
        label: String = "machine",
        guestType: String? = nil,
    ) throws -> String {
        let sanitized = try sanitizeQEMUArg(value, label: label)
        if let guestType {
            let profile = try GuestProfiles.require(guestType)
            guard sanitized == profile.machine else {
                throw BarkVisorError.invalidArgument(
                    "\(label) must be \(profile.machine) for guestType \(guestType)",
                )
            }
            return sanitized
        }
        guard GuestProfiles.qemuMachines.contains(sanitized) else {
            let list = GuestProfiles.qemuMachines.sorted().joined(separator: ", ")
            throw BarkVisorError.invalidArgument("\(label) must be one of: \(list)")
        }
        return sanitized
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
        try GuestProfiles.require(vmType).qemuBinaryName
    }

    public static func binary(for vmType: String) throws -> URL {
        try resolveQEMU(binaryName(for: vmType))
    }

    public static func launchConfig(ctx: QEMUBuildContext) throws -> QEMULaunchConfig {
        let effective = try EffectiveWorkloadPipeline.resolve(ctx.spec)
        let spec = effective.resolved
        let disk = ctx.disk
        let guestType = effective.launchGuestType
        let profile = try GuestProfiles.require(guestType)
        let qemuBinary = try binary(for: guestType)
        let vmID = spec.metadata.id ?? ctx.vm.id

        _ = try sanitizeQEMUArg(disk.path, label: "Disk path")
        _ = try sanitizeQEMUArg(disk.format, label: "Disk format")

        let windows = profile.isWindows
        let bootOrder = spec.spec.bootOrder ?? "cd"
        let diskFirst = bootOrder.first == "c"
        let machine = try validateMachine(
            spec.spec.machine ?? profile.machine,
            guestType: guestType,
        )
        let accelerator = effective.accelerator ?? QEMUBuilder.accelerator
        let backend = WorkloadBackendProjector.project(
            guestType: guestType,
            accelerator: accelerator,
        )

        var args: [String] = []
        args += [
            "-machine", machine, "-accel", backend.accelerator,
            "-cpu", cpuModel(for: backend.accelerator),
        ]
        if effective.hugepages {
            args += try hugepagesArgs()
        }
        args += specResourceArgs(spec)
        args += try firmwareArgs(spec: spec, vmID: vmID, vmType: guestType)
        args += ["-device", "qemu-xhci"]
        args += bootDiskArgs(disk: disk, windows: windows, diskFirst: diskFirst)
        args += try isoArgs(isos: ctx.isos, windows: windows, diskFirst: diskFirst)
        args += try cloudInitArgs(spec: spec)
        args += try sharedFolderArgs(spec: spec)
        let tpm = try tpmArgs(spec: spec, vmID: vmID, guestType: guestType)
        args += tpm.args
        args += try additionalDiskArgs(ctx.additionalDisks)
        let klass = try WorkloadClass.parse(spec.spec.workloadClass)
        let allowHostOllama = klass == .agent && AgentNetworkCage.allowHostOllama(
            userData: CloudInitService.storedUserData(vmID: vmID),
        )
        let (netArgs, needsSocketVmnetWrap) = try networkArgs(
            spec: spec,
            network: ctx.network,
            allowHostOllama: allowHostOllama,
            loopbackHostfwds: ctx.loopbackHostfwds,
        )
        args += netArgs
        args += socketArgs(
            ctx.sockets,
            vdagentClipboard: QEMUChardev.supportsVdagent(binary: qemuBinary),
        )
        args += displayAndInputArgs(spec: spec)
        args += try usbPassthroughArgs(spec: spec)
        args += try miscArgs(spec: spec, vmID: vmID)

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

        let launch = QEMULaunchConfig(
            executable: qemuBinary, arguments: args,
            swtpmExecutable: tpm.exe, swtpmArguments: tpm.swtpmArgs, swtpmStateDir: tpm.dir,
        )
        return try AgentNetworkCage.wrapLaunch(
            launch, workloadClass: klass, allowHostOllama: allowHostOllama,
        )
    }

    // MARK: - Argument Builders

    /// CPU/memory from WorkloadSpec only (PAS-35 — no parallel VM-column parse).
    static func specResourceArgs(_ spec: WorkloadSpec) -> [String] {
        [
            "-smp", "\(spec.spec.resources.cpu)",
            "-m", "\(spec.spec.resources.memoryMb)M",
        ]
    }

    /// pflash drives when spec.firmware.uefi is on (default true; PAS-93).
    static func firmwareArgs(spec: WorkloadSpec, vmID: String, vmType: String) throws -> [String] {
        guard spec.spec.firmware?.uefi ?? true else { return [] }
        let (codeImage, varsImage) = try prepareFirmware(vmID: vmID, vmType: vmType)
        return [
            "-drive", "if=pflash,format=raw,readonly=on,file=\(codeImage.path)",
            "-drive", "if=pflash,format=raw,file=\(varsImage.path)",
        ]
    }

    private static func bootDiskArgs(disk: Disk, windows: Bool, diskFirst: Bool) -> [String] {
        let diskBootIndex = diskFirst ? 0 : 1
        let driveArgs = [
            "-drive",
            "file=\(disk.path),format=\(disk.format),if=none,id=\(QEMUDeviceNames.bootDrive),cache=writeback",
        ]
        let boot = QEMUDeviceNames.bootDrive
        let deviceType = windows ? "nvme,drive=\(boot),serial=boot" : "virtio-blk-pci,drive=\(boot)"
        return driveArgs + ["-device", "\(deviceType),bootindex=\(diskBootIndex)"]
    }

    private static func isoArgs(isos: [VMImage], windows: Bool, diskFirst: Bool) throws -> [String] {
        var args: [String] = []
        for (i, iso) in isos.enumerated() {
            guard let isoPath = iso.path else { continue }
            let sanitizedISOPath = try sanitizeQEMUArg(isoPath, label: "ISO path")
            let driveId = QEMUDeviceNames.cdromDrive(i)
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

    private static func cloudInitArgs(spec: WorkloadSpec) throws -> [String] {
        guard let ciPath = spec.spec.cloudInit?.userDataRef else { return [] }
        let sanitizedCIPath = try sanitizeQEMUArg(ciPath, label: "Cloud-init ISO path")
        return ["-drive", "file=\(sanitizedCIPath),format=raw,if=virtio,readonly=on,media=cdrom"]
    }

    private static func sharedFolderArgs(spec: WorkloadSpec) throws -> [String] {
        let paths = spec.spec.sharedPaths ?? []
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

    private static func tpmArgs(spec: WorkloadSpec, vmID: String, guestType: String) throws
        -> (args: [String], exe: URL?, swtpmArgs: [String]?, dir: URL?) {
        guard spec.spec.firmware?.tpm == true else { return ([], nil, nil, nil) }
        let tpmStateDir = Config.dataDir.appendingPathComponent("tpm/\(vmID)")
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
        let isX86 = (try? GuestProfiles.require(guestType).isX86) == true
        let tpmDevice = isX86 ? "tpm-tis,tpmdev=tpm0" : "tpm-tis-device,tpmdev=tpm0"
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
                "file=\(sanitizedPath),format=\(sanitizedFormat),if=virtio,cache=writeback,id=\(QEMUDeviceNames.extraDrive(i))",
            ]
        }
        return args
    }

    /// Internal for tests (PAS-67). Missing `network` is implicit NAT.
    static func networkArgs(
        spec: WorkloadSpec,
        network: Network?,
        allowHostOllama: Bool = false,
        loopbackHostfwds: [QEMULoopbackForward] = [],
    ) throws -> (args: [String], needsSocketVmnetWrap: Bool) {
        guard spec.spec.networks.count <= 1 else {
            throw BarkVisorError.badRequest(
                "spec.networks supports at most 1 network until multi-NIC is available",
            )
        }
        var netdevArgs = ""
        var deviceArgs = "virtio-net-pci,netdev=net0"
        // True only when QEMU must be exec'd under socket_vmnet_client (macOS bridged).
        var needsSocketVmnetWrap = false
        let specNet = spec.spec.networks.first
        let forwards = specNet?.portForwards ?? []
        let mode = try NetworkCapability.effectiveMode(of: network)
        try NetworkCapability.requirePortForwardsAllowed(count: forwards.count, mode: mode)

        if let mac = specNet?.mac, !mac.isEmpty {
            try validateMAC(mac)
            deviceArgs += ",mac=\(mac)"
        }

        switch mode {
        case .bridged:
            guard let net = network else {
                throw BarkVisorError.badRequest("Bridged mode requires a Network record")
            }
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
                try NetworkCapability.requireBridgedInterface(br)
                let safeBr = try sanitizeQEMUArg(br, label: "Bridge interface")
                netdevArgs = "bridge,id=net0,br=\(safeBr)"
                needsSocketVmnetWrap = false
            #else
                throw BarkVisorError.unsupportedFeature(.bridgedNetworking)
            #endif
        case .isolated:
            // Private: slirp with restrict=on — no host, LAN, or internet.
            netdevArgs = "user,id=net0,restrict=on"
            if let dns = network?.dnsServer, !dns.isEmpty {
                try validateIPv4(dns)
                netdevArgs += ",dns=\(dns)"
            }
        case .nat:
            netdevArgs = "user,id=net0"
            let klass = try WorkloadClass.parse(spec.spec.workloadClass)
            if klass == .agent {
                netdevArgs += AgentNetworkCage.slirpExtras(
                    mode: .nat, allowHostOllama: allowHostOllama,
                )
            }
            if let dns = network?.dnsServer, !dns.isEmpty {
                try validateIPv4(dns)
                netdevArgs += ",dns=\(dns)"
            }
            for rule in forwards {
                try validateProtocol(rule.proto)
                try validatePort(rule.hostPort)
                try validatePort(rule.guestPort)
                netdevArgs += ",hostfwd=\(rule.proto)::\(rule.hostPort)-:\(rule.guestPort)"
            }
            for fwd in loopbackHostfwds {
                try validatePort(fwd.hostPort)
                try validatePort(fwd.guestPort)
                let fwdArg = CodingAgentSession.loopbackHostfwd(
                    hostPort: fwd.hostPort,
                    guestPort: fwd.guestPort,
                )
                netdevArgs += ",\(fwdArg)"
            }
        }

        return (["-netdev", netdevArgs, "-device", deviceArgs], needsSocketVmnetWrap)
    }

    /// Serial, VNC, QMP, guest-agent, and optional qemu-vdagent (VNC clipboard).
    /// `-vnc clipboard=on` is not a QEMU 11 VNC option (start fails). Guest
    /// clipboard goes through qemu-vdagent + spice-vdagent in a desktop guest
    /// when this Device's QEMU was built with that chardev.
    static func socketArgs(_ sockets: VMSockets, vdagentClipboard: Bool) -> [String] {
        var args = [
            "-chardev", "socket,id=serial0,path=\(sockets.serial.path),server=on,wait=off",
            "-serial", "chardev:serial0",
            // lossy=on enables Tight+JPEG in QEMU's VNC server (much less bandwidth/CPU
            // than raw/hextile for typical desktop sessions; noVNC negotiates JPEG quality).
            "-vnc", "unix:\(sockets.vnc.path),lossy=on",
            "-qmp", "unix:\(sockets.qmp.path),server,nowait",
            "-qmp", "unix:\(sockets.event.path),server,nowait",
            "-device", "virtio-serial-pci",
            "-chardev", "socket,path=\(sockets.guestAgent.path),server=on,wait=off,id=qga0",
            "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
        ]
        if vdagentClipboard {
            args += [
                "-chardev", "qemu-vdagent,id=vdagent,name=vdagent,clipboard=on",
                "-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0",
            ]
        }
        return args
    }

    private static func displayAndInputArgs(spec: WorkloadSpec) -> [String] {
        let resolution = spec.spec.display?.resolution ?? "1280x800"
        var args = ["-device", "ramfb"]
        if let (w, h) = try? validateResolution(resolution) {
            args += ["-device", "virtio-gpu-pci,xres=\(w),yres=\(h)"]
        } else {
            args += ["-device", "virtio-gpu-pci"]
        }
        return args + ["-device", "usb-kbd", "-device", "usb-tablet"]
    }

    private static func usbPassthroughArgs(spec: WorkloadSpec) throws -> [String] {
        guard !spec.spec.usb.isEmpty else { return [] }
        try AgentWorkloadPolicy.assertUSBAllowed(spec.spec.workloadClass)
        let hostDevices = try USBDeviceService.listDevices()
        return try usbHostArgs(usb: spec.spec.usb, hostDevices: hostDevices)
    }

    /// Builds `usb-host` args. Serial identity resolves first; live `hostbus`/
    /// `hostaddr` are emitted after that match. `bus:BBB.AAA` and vendor/product
    /// are not selection ids. Missing topology fails closed.
    public static func usbHostArgs(
        usb: [WorkloadUSBDevice],
        hostDevices: [HostUSBDevice],
    ) throws -> [String] {
        guard !usb.isEmpty else { return [] }
        try PlatformCapabilities.requireUSBPassthrough()
        var args: [String] = []
        for (i, specDev) in usb.enumerated() {
            try validateUSBId(specDev.vendorId)
            try validateUSBId(specDev.productId)
            let stored = USBPassthroughService.passthrough(from: specDev)
            let deviceArg = try usbHostDeviceArg(stored: stored, hostDevices: hostDevices, index: i)
            args += ["-device", deviceArg]
        }
        return args
    }

    private static func usbHostDeviceArg(
        stored: USBPassthroughDevice,
        hostDevices: [HostUSBDevice],
        index: Int,
    ) throws -> String {
        let suffix = ",guest-reset=off,id=usb-pt-\(index)"
        if let deviceId = stored.deviceId, USBDeviceIdentity.isBusAddressId(deviceId) {
            throw USBPassthroughService.busAddressIdentityError(deviceId)
        }

        let lookup = stored.deviceId ?? USBDeviceIdentity.make(
            vendorId: stored.vendorId,
            productId: stored.productId,
            serial: stored.serialNumber,
        ).id
        let host = try USBPassthroughService.resolve(deviceId: lookup, hostDevices: hostDevices)
        guard host.attachable else {
            throw BarkVisorError.badRequest(
                host.excludedReason ?? USBDeviceIdentity.massStorageExclusionReason,
            )
        }
        if let bus = host.bus, let address = host.address {
            return "usb-host,hostbus=\(bus),hostaddr=\(address)\(suffix)"
        }
        throw BarkVisorError.conflict(
            "USB device \(lookup) resolved without bus/address; refusing vendor/product fallback",
        )
    }

    private static func miscArgs(spec: WorkloadSpec, vmID: String) throws -> [String] {
        let sanitizedName = try sanitizeQEMUArg(spec.metadata.name, label: "VM name")
        var args: [String] = [
            "-device", "virtio-balloon-pci",
            "-device", "virtio-rng-pci",
            "-name", sanitizedName, "-uuid", vmID,
        ]
        if let dataDir = BundleResolver.qemuDataDir() {
            args += ["-L", dataDir.path]
        }
        args += ["-display", "none"]
        return args
    }

    // MARK: - Firmware

    private static func prepareFirmware(vmID: String, vmType: String) throws -> (code: URL, vars: URL) {
        let profile = try GuestProfiles.require(vmType)
        let fwDir = Config.dataDir.appendingPathComponent("efivars/\(vmID)")
        try FileManager.default.createDirectory(at: fwDir, withIntermediateDirectories: true)
        let varsFile = fwDir.appendingPathComponent("vars.fd")

        switch profile.firmware {
        case .aavmfSecureBoot:
            // Windows ARM64 needs AAVMF secure boot firmware.
            let codeFile = try resolveAAVMFSecureBoot()
            try ensureVarsStore(
                at: varsFile,
                codePath: codeFile.path,
                templateCandidates: PlatformQEMU.aavmfVarsCandidates,
                zeroFillBytes: 67_108_864,
            )
            return (codeFile, varsFile)
        case .edk2ARM64:
            let codeFile = try resolveEDK2ARM64()
            try ensureVarsStore(
                at: varsFile,
                codePath: codeFile.path,
                templateCandidates: PlatformQEMU.aavmfVarsCandidates,
                zeroFillBytes: 67_108_864,
            )
            return (codeFile, varsFile)
        case .edk2X86:
            let codeFile = try resolveEDK2X86_64()
            try ensureVarsStore(
                at: varsFile,
                codePath: codeFile.path,
                templateCandidates: PlatformQEMU.edk2X86VarsCandidates,
                zeroFillBytes: 540_672,
            )
            return (codeFile, varsFile)
        case .ovmfSecureBoot:
            let codeFile = try resolveOVMFSecureBoot()
            try ensureVarsStore(
                at: varsFile,
                codePath: codeFile.path,
                templateCandidates: PlatformQEMU.ovmfSecureBootVarsCandidates,
                zeroFillBytes: 540_672,
            )
            return (codeFile, varsFile)
        }
    }

    /// Create per-VM NVRAM from the distro OVMF/AAVMF template when possible.
    /// Zero-filled vars.fd often boots to BdsDxe "No bootable option" even with a valid ESP.
    private static func ensureVarsStore(
        at varsFile: URL,
        codePath: String,
        templateCandidates: [String],
        zeroFillBytes: Int,
    ) throws {
        guard !FileManager.default.fileExists(atPath: varsFile.path) else { return }

        // Prefer a VARS file that matches the CODE variant (4M / secboot).
        var candidates = templateCandidates
        candidates = preferMatchingFirmwareToken("secboot", in: candidates, codePath: codePath)
        candidates = preferMatchingFirmwareToken("4M", in: candidates, codePath: codePath)

        if let template = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            try FileManager.default.copyItem(atPath: template, toPath: varsFile.path)
            return
        }
        FileManager.default.createFile(atPath: varsFile.path, contents: Data(count: zeroFillBytes))
    }

    // MARK: - socket_vmnet resolution

    static func isSharedSocketVmnetPath(_ path: String) -> Bool {
        SocketVmnetDiscovery.isSharedSocketPath(path)
    }

    /// Per-iface (operator lima plist) then Homebrew shared `brew services` socket.
    public static func socketVmnetSocketCandidates(bridgeInterface: String) -> [String] {
        SocketVmnetDiscovery.candidates(bridgeInterface: bridgeInterface)
    }

    /// Resolve an existing `socket_vmnet` socket. BarkVisor does not start the daemon.
    static func resolveSocketVmnetSocketPath(
        bridgeInterface: String?,
        dbSocketPath: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) throws -> String {
        if let dbPath = dbSocketPath, fileExists(dbPath), !isSharedSocketVmnetPath(dbPath) {
            return dbPath
        }
        let iface = bridgeInterface ?? "en0"
        guard let socketPath = socketVmnetSocketCandidates(bridgeInterface: iface).first(where: fileExists)
        else {
            throw BarkVisorError.processSpawnFailed(
                "socket_vmnet daemon socket not found. "
                    + SocketVmnetDiscovery.installHint,
            )
        }
        return socketPath
    }

    public static func resolveSocketVmnet(bridgeInterface: String?, dbSocketPath: String? = nil)
        throws -> (client: URL, socketPath: String) {
        #if os(macOS)
            let clientBin = try BundleResolver.optHelper(
                "socket_vmnet_client",
                package: "socket_vmnet",
                extraPaths: ["/opt/socket_vmnet/bin/socket_vmnet_client"],
            )
            let socketPath = try resolveSocketVmnetSocketPath(
                bridgeInterface: bridgeInterface,
                dbSocketPath: dbSocketPath,
            )
            return (clientBin, socketPath)
        #else
            throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
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

    /// Reorder firmware VARS candidates so the CODE variant (secboot / 4M) is tried first.
    private static func preferMatchingFirmwareToken(
        _ token: String,
        in candidates: [String],
        codePath: String,
    ) -> [String] {
        let match = candidates.filter { $0.contains(token) }
        let rest = candidates.filter { !$0.contains(token) }
        if codePath.contains(token) {
            return match + rest
        }
        return rest + match
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

    private static func resolveOVMFSecureBoot() throws -> URL {
        if let url = BundleResolver.qemuResource("OVMF_CODE.secboot.fd") {
            return url
        }
        if let url = BundleResolver.qemuResource("OVMF_CODE_4M.secboot.fd") {
            return url
        }
        if let found = PlatformQEMU.ovmfSecureBootCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) {
            return URL(fileURLWithPath: found)
        }
        // Prefer secboot; fall back to regular OVMF when the host only ships that.
        return try resolveEDK2X86_64()
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
