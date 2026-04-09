import Foundation
import GRDB
import os

struct VMSockets {
    let vnc: URL
    let monitor: URL
    let serial: URL
    let qmp: URL
    let event: URL

    init(vmID: String) {
        let shortID = String(vmID.prefix(12))
        vnc = Config.socketDir.appendingPathComponent("\(shortID)-vnc.sock")
        monitor = Config.socketDir.appendingPathComponent("\(shortID)-mon.sock")
        serial = Config.socketDir.appendingPathComponent("\(shortID)-ser.sock")
        qmp = Config.socketDir.appendingPathComponent("\(shortID)-qmp.sock")
        event = Config.socketDir.appendingPathComponent("\(shortID)-evt.sock")
    }

    func removeStale() {
        for url in [vnc, monitor, serial, qmp] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func setOwnerOnlyPermissions() {
        for sockPath in [vnc.path, qmp.path, serial.path, monitor.path] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: sockPath,
            )
        }
    }
}

extension VMManager {
    // MARK: - Bridge Validation

    func validateBridgeIfNeeded(network: Network?) async throws -> String? {
        guard let network, network.mode == "bridged" else { return nil }

        let iface = network.bridge ?? "en0"
        let bridge = try await dbPool.read { db in
            try BridgeRecord.filter(Column("interface") == iface).fetchOne(db)
        }
        if bridge?.status != "active" {
            let detail = bridge.map { "status: \($0.status)" } ?? "no bridge record"
            throw BarkVisorError.bridgeNotReady(
                "Bridge for \(iface) is not active (\(detail)). "
                    + "Set up the bridge in Network settings.",
            )
        }
        return bridge?.socketPath
    }

    // MARK: - swtpm

    func startSwtpmIfNeeded(
        launch: QEMULaunchConfig, vmID: String, vmName: String,
    ) async throws -> Process? {
        guard let swtpmExe = launch.swtpmExecutable,
              let swtpmArgs = launch.swtpmArguments
        else {
            return nil
        }

        let tpmProc = Process()
        tpmProc.executableURL = swtpmExe
        tpmProc.arguments = swtpmArgs
        tpmProc.standardOutput = FileHandle.nullDevice
        let swtpmStderrPipe = Pipe()
        tpmProc.standardError = swtpmStderrPipe
        try tpmProc.run()

        let swtpmVmId = vmID
        swtpmStderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines,
            ), !line.isEmpty {
                let lower = line.lowercased()
                if lower.contains("error") || lower.contains("fatal") || lower.contains("failed") {
                    Log.vm.error("swtpm: \(line)", vm: swtpmVmId)
                }
            }
        }
        // Wait for swtpm socket to appear
        try await Task.sleep(nanoseconds: 500_000_000)
        Log.vm.info("swtpm started for VM \(vmName)", vm: vmID)
        return tpmProc
    }

    // MARK: - Logging

    func logLaunchCommand(
        launch: QEMULaunchConfig, network: Network?, vmName: String, vmID: String,
    ) {
        let fullCommand = ([launch.executable.path] + launch.arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
        let netInfo =
            if let net = network {
                "mode=\(net.mode), bridge=\(net.bridge ?? "none")"
            } else {
                "none (NAT)"
            }
        Log.vm.info("Starting VM \(vmName): \(launch.executable.path)", vm: vmID)
        Log.vm.info("Launch command: \(fullCommand)", vm: vmID)
        Log.vm.info("Network: \(netInfo)", vm: vmID)
    }

    // MARK: - QEMU Process

    func configureQEMUProcess(
        launch: QEMULaunchConfig, vmID: String,
    ) -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set termination handler BEFORE run() to avoid race window
        // where early process exit could be missed
        let vmIDCopy = vmID
        process.terminationHandler = { [weak self] proc in
            Task { [weak self] in
                await self?.handleTermination(vmID: vmIDCopy, status: proc.terminationStatus)
            }
        }

        return (process, stdoutPipe, stderrPipe)
    }

    // MARK: - Socket Readiness

    func waitForQMPSocket(
        process: Process, qmpSock: URL, stderrPipe: Pipe, stdoutPipe: Pipe, vmID: String,
    ) async throws {
        // Poll for QMP socket readiness (up to 5s) instead of fixed sleep
        let qmpReady = await Task.detached(priority: .utility) {
            for _ in 0 ..< 50 { // 50 × 100ms = 5s
                if FileManager.default.fileExists(atPath: qmpSock.path) { return true }
                if !process.isRunning { return false }
                usleep(100_000) // 100ms
            }
            return process.isRunning
        }.value

        guard qmpReady, process.isRunning else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            // Close pipes explicitly since readabilityHandlers haven't been set yet
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            let fullMsg = "QEMU exited with status \(process.terminationStatus): \(errMsg)"
            Log.vm.error("VM failed to start: \(fullMsg)", vm: vmID)
            throw BarkVisorError.processSpawnFailed(fullMsg)
        }
    }

    func waitForVNCAndSerialSockets(
        process: Process, vncSock: URL, serialSock: URL, vmID: String,
    ) async throws {
        // Wait for VNC and serial sockets to be created by QEMU (up to 5s)
        let socketsReady = await Task.detached(priority: .utility) {
            for _ in 0 ..< 50 { // 50 × 100ms = 5s
                let vncExists = FileManager.default.fileExists(atPath: vncSock.path)
                let serialExists = FileManager.default.fileExists(atPath: serialSock.path)
                if vncExists, serialExists { return true }
                if !process.isRunning { return false }
                usleep(100_000) // 100ms
            }
            return process.isRunning
        }.value

        guard socketsReady, process.isRunning else {
            let fullMsg =
                "QEMU exited before VNC/serial sockets were ready (status \(process.terminationStatus))"
            Log.vm.error("VM failed to start: \(fullMsg)", vm: vmID)
            throw BarkVisorError.processSpawnFailed(fullMsg)
        }
    }

    // MARK: - Pipe Handlers

    func attachPipeHandlers(stdoutPipe: Pipe, stderrPipe: Pipe, vmID: String) {
        // Drain QEMU stdout (discard) and stderr (log errors only)
        let logVmId = vmID
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines,
            ), !text.isEmpty {
                // Suppress harmless macOS libusb warnings during USB passthrough
                if text.contains("libusb_kernel_driver_active")
                    || text.contains("libusb_detach_kernel_driver") {
                    return
                }
                Log.vm.error("QEMU: \(text)", vm: logVmId)
            }
        }
    }

    // MARK: - swtpm Cleanup

    func cleanupFailedSwtpm(_ swtpmProc: Process?, vmID: String) {
        guard let swtpmProc, swtpmProc.isRunning else { return }

        let swtpmPid = swtpmProc.processIdentifier
        swtpmProc.terminate()
        // Escalate to SIGKILL if swtpm doesn't exit promptly
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if swtpmProc.isRunning {
                kill(swtpmPid, SIGKILL)
            }
        }
        Log.vm.info(
            "Terminated orphaned swtpm (PID \(swtpmPid)) after QEMU start failure for VM \(vmID)",
            vm: vmID,
        )
    }
}
