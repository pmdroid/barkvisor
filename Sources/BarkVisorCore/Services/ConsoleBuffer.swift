import Foundation
import NIOCore
import NIOPosix

/// Manages per-VM console buffers. Connects to the serial socket immediately when a VM starts,
/// records all output into a disk-backed scrollback buffer, and replays it to new WebSocket clients.
public actor ConsoleBufferManager {
    private var buffers: [String: VMConsoleBuffer] = [:]
    private let eventLoopGroup: EventLoopGroup

    public init(eventLoopGroup: EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
    }

    /// Called when a VM starts — begins recording serial output immediately
    public func attach(vmID: String, serialSocketPath: String) {
        let buffer = VMConsoleBuffer(
            vmID: vmID, serialSocketPath: serialSocketPath, eventLoopGroup: eventLoopGroup,
        )
        buffers[vmID] = buffer
        Task { await buffer.connect() }
    }

    /// Called when a VM stops
    public func detach(vmID: String) {
        if let buffer = buffers.removeValue(forKey: vmID) {
            Task { await buffer.disconnect() }
        }
        // Remove persisted scrollback
        try? FileManager.default.removeItem(at: VMConsoleBuffer.scrollbackPath(vmID: vmID))
    }

    /// Get scrollback data for replay (reads from disk)
    public func scrollback(vmID: String) -> Data {
        guard let buffer = buffers[vmID] else {
            // VM not currently running — try to load persisted scrollback
            return VMConsoleBuffer.loadPersistedScrollback(vmID: vmID)
        }
        return buffer.scrollbackData
    }

    /// Write input data to the serial socket (from WebSocket client)
    public func write(vmID: String, data: Data) async {
        await buffers[vmID]?.write(data)
    }

    /// Register a WebSocket listener to receive live output
    public func addListener(vmID: String, id: String, callback: @escaping @Sendable ([UInt8]) -> Void) {
        buffers[vmID]?.addListener(id: id, callback: callback)
    }

    /// Remove a WebSocket listener
    public func removeListener(vmID: String, id: String) {
        buffers[vmID]?.removeListener(id: id)
    }
}

/// Per-VM console buffer with disk-backed scrollback and live listeners
public final class VMConsoleBuffer: @unchecked Sendable {
    public let vmID: String
    public let serialSocketPath: String
    private let eventLoopGroup: EventLoopGroup

    private let lock = NSLock()
    private let maxScrollback = 5 * 1_024 * 1_024 // 5 MB
    private let compactThreshold = 6 * 1_024 * 1_024 // compact when file exceeds 6 MB
    private let scrollbackFileURL: URL
    private var fileHandle: FileHandle?
    private var fileSize: Int = 0
    private var channel: Channel?
    private var listeners: [String: @Sendable ([UInt8]) -> Void] = [:]
    private var logLineBuffer = Data()
    private var logFlushTask: Task<Void, Never>?

    public static func consoleDir() -> URL {
        Config.dataDir.appendingPathComponent("console")
    }

    public static func scrollbackPath(vmID: String) -> URL {
        consoleDir().appendingPathComponent("\(vmID).bin")
    }

    /// Load persisted scrollback for a VM that isn't currently running
    public static func loadPersistedScrollback(vmID: String) -> Data {
        let path = scrollbackPath(vmID: vmID)
        return (try? Data(contentsOf: path)) ?? Data()
    }

    public var scrollbackData: Data {
        lock.lock()
        defer { lock.unlock() }
        let path = scrollbackFileURL
        return (try? Data(contentsOf: path)) ?? Data()
    }

    public init(vmID: String, serialSocketPath: String, eventLoopGroup: EventLoopGroup) {
        self.vmID = vmID
        self.serialSocketPath = serialSocketPath
        self.eventLoopGroup = eventLoopGroup
        self.scrollbackFileURL = Self.scrollbackPath(vmID: vmID)
        openOrCreateFile()
    }

    private func openOrCreateFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: scrollbackFileURL.path) {
            fm.createFile(
                atPath: scrollbackFileURL.path, contents: nil, attributes: [.posixPermissions: 0o600],
            )
        }
        do {
            let handle = try FileHandle(forUpdating: scrollbackFileURL)
            handle.seekToEndOfFile()
            fileSize = Int(handle.offsetInFile)
            fileHandle = handle
        } catch {
            Log.vm.error(
                "Failed to open console scrollback file for \(self.vmID): \(error)", vm: self.vmID,
            )
        }
    }

    private func setChannel(_ ch: Channel) {
        lock.lock()
        channel = ch
        lock.unlock()
    }

    private func getChannel() -> Channel? {
        lock.lock()
        let ch = channel
        lock.unlock()
        return ch
    }

    private func clearForDisconnect() -> Channel? {
        lock.lock()
        let ch = channel
        channel = nil
        listeners.removeAll()
        logLineBuffer.removeAll()
        let flushTask = logFlushTask
        logFlushTask = nil
        let handle = fileHandle
        lock.unlock()
        flushTask?.cancel()
        try? handle?.synchronize()
        return ch
    }

    private func clearLogBufferIfNeeded(partialCount: Int) {
        lock.lock()
        if logLineBuffer.count <= partialCount {
            logLineBuffer.removeAll()
        }
        lock.unlock()
    }

    /// Compact the scrollback file by keeping only the last `maxScrollback` bytes (FIFO)
    private func compactIfNeeded() {
        guard fileSize > compactThreshold else { return }
        fileHandle?.closeFile()
        fileHandle = nil
        do {
            let data = try Data(contentsOf: scrollbackFileURL)
            let trimmed = data.suffix(maxScrollback)
            try trimmed.write(to: scrollbackFileURL)
            let handle = try FileHandle(forUpdating: scrollbackFileURL)
            handle.seekToEndOfFile()
            fileSize = Int(handle.offsetInFile)
            fileHandle = handle
        } catch {
            Log.vm.error("Failed to compact console scrollback for \(self.vmID): \(error)", vm: self.vmID)
            // Try to reopen
            openOrCreateFile()
        }
    }

    public func connect() async {
        do {
            let ch = try await ClientBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(ConsoleRecorderHandler(buffer: self))
                }
                .connect(unixDomainSocketPath: serialSocketPath)
                .get()
            setChannel(ch)
        } catch {
            Log.vm.error("Failed to connect console buffer for \(self.vmID): \(error)", vm: self.vmID)
        }
    }

    public func disconnect() async {
        let ch = clearForDisconnect()
        try? await ch?.close()
    }

    public func recordOutput(_ bytes: [UInt8]) {
        var needsCompact = false
        var currentListeners: [String: @Sendable ([UInt8]) -> Void]

        lock.lock()
        // Append to disk — reopen file if handle was lost
        if fileHandle == nil {
            openOrCreateFile()
        }
        fileHandle?.write(Data(bytes))
        fileSize += bytes.count
        needsCompact = fileSize > compactThreshold

        currentListeners = listeners

        logLineBuffer.append(contentsOf: bytes)
        var linesToFlush: [String] = []
        while let newlineIdx = logLineBuffer.firstIndex(of: 0x0A) {
            let lineData = logLineBuffer[logLineBuffer.startIndex ... newlineIdx]
            if let line = String(data: Data(lineData), encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)
                .trimmingCharacters(in: .whitespaces),
                !line.isEmpty {
                linesToFlush.append(line)
            }
            logLineBuffer.removeSubrange(logLineBuffer.startIndex ... newlineIdx)
        }
        logFlushTask?.cancel()
        let hasPartial = !logLineBuffer.isEmpty
        let partialData = hasPartial ? Data(logLineBuffer) : nil
        if let partial = partialData {
            logFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.clearLogBufferIfNeeded(partialCount: partial.count)
            }
        } else {
            logFlushTask = nil
        }
        lock.unlock()

        // Compact outside the lock to avoid blocking listeners during disk I/O
        if needsCompact {
            compactIfNeeded()
        }

        // Notify listeners without holding the lock to avoid deadlocks
        for (_, callback) in currentListeners {
            callback(bytes)
        }
    }

    public func write(_ data: Data) async {
        guard let ch = getChannel() else { return }
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        try? await ch.writeAndFlush(buf)
    }

    public func addListener(id: String, callback: @escaping @Sendable ([UInt8]) -> Void) {
        lock.lock()
        listeners[id] = callback
        lock.unlock()
    }

    public func removeListener(id: String) {
        lock.lock()
        listeners.removeValue(forKey: id)
        lock.unlock()
    }
}

/// NIO handler that records all incoming serial data into the buffer
public final class ConsoleRecorderHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    private let buffer: VMConsoleBuffer

    public init(buffer: VMConsoleBuffer) {
        self.buffer = buffer
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        guard let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        buffer.recordOutput(bytes)
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
