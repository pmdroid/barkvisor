#if !os(Windows)
    import Foundation
    #if os(Linux)
        import Glibc
    #elseif os(macOS)
        import Darwin
    #endif

    /// PTY-backed child process (issue #609 — app workload `docker exec` terminal).
    ///
    /// macOS forks the child onto a pseudo-terminal with `forkpty`; Linux uses
    /// `openpty` + `fork` and attaches the slave to stdio in the child. Either
    /// way Docker sees a TTY and the parent bridges the master fd: bytes in →
    /// child stdin, bytes out → `onData`, `TIOCSWINSZ` on the master → window
    /// resize for `docker exec -it`.
    ///
    /// Lifecycle: `start` → read loop streams child output through `onData`;
    /// when the child exits the reaper collects its status, the read side hits
    /// EOF/EIO, and `onExit` fires exactly once. `terminate` kills and reaps
    /// the child; the master fd closes only after both loops are done so it
    /// can never be reused under a blocked read().
    public final class PTYProcess: @unchecked Sendable {
        public typealias DataHandler = @Sendable ([UInt8]) -> Void
        public typealias ExitHandler = @Sendable (Int32) -> Void

        private let lock = NSLock()
        private var masterFD: Int32 = -1
        private var childPID: pid_t = -1
        private var started = false
        private var killed = false
        private var readDone = false
        private var reapDone = false
        private var finished = false
        private var exitCode: Int32 = -1
        private var onData: DataHandler?
        private var onExit: ExitHandler?

        public init() {}

        /// Handlers must be installed before `start`.
        public func configure(onData: @escaping DataHandler, onExit: @escaping ExitHandler) {
            lock.lock()
            self.onData = onData
            self.onExit = onExit
            lock.unlock()
        }

        public var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started && !finished
        }

        /// Fork the child onto a new PTY and `execv` the given program.
        @discardableResult
        public func start(executable: String, arguments: [String]) throws -> pid_t {
            lock.lock()
            guard !started else {
                lock.unlock()
                throw BarkVisorError.badRequest("PTYProcess already started")
            }
            lock.unlock()

            var cargs: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
                + [nil]
            defer { for ptr in cargs where ptr != nil {
                free(ptr)
            } }

            guard let forked = try PTYProcess.forkAttached(cargs: cargs) else {
                let reason = String(cString: strerror(errno))
                throw BarkVisorError.internalError("pty spawn failed: \(reason)")
            }

            lock.lock()
            masterFD = forked.master
            childPID = forked.pid
            started = true
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.readLoop(forked.master)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.reapLoop(forked.pid)
            }
            return forked.pid
        }

        public func write(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            lock.lock()
            let fd = masterFD
            let live = started && !finished
            lock.unlock()
            guard live, fd >= 0 else { return }
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                var offset = 0
                var remaining = raw.count
                while remaining > 0 {
                    let n = Foundation.write(fd, ptr + offset, remaining)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    if n == 0 { return }
                    offset += n
                    remaining -= n
                }
            }
        }

        /// `TIOCSWINSZ` on the master works on both platforms (XNU's ptmx
        /// device and the Linux pty driver both accept it).
        public func resize(cols: Int, rows: Int) {
            let c = UInt16(max(1, min(cols, 9_999)))
            let r = UInt16(max(1, min(rows, 9_999)))
            lock.lock()
            let fd = masterFD
            let live = started && !finished
            lock.unlock()
            guard live, fd >= 0 else { return }
            var ws = winsize(ws_row: r, ws_col: c, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
        }

        /// Kill the child; the reaper collects it and `onExit` fires once.
        public func terminate() {
            lock.lock()
            let pid = childPID
            let already = killed || !started || finished
            killed = true
            lock.unlock()
            guard !already, pid > 0 else { return }
            kill(pid, SIGKILL)
        }

        // MARK: - Fork

        /// Returns `(pid, masterFd)` in the parent; the child only makes
        /// async-signal-safe syscalls before `execv` and never returns.
        private static func forkAttached(
            cargs: [UnsafeMutablePointer<CChar>?],
        ) -> (pid: pid_t, master: Int32)? {
            #if os(macOS)
                var master: Int32 = 0
                let pid: pid_t = forkpty(&master, nil, nil, nil)
                if pid == 0 {
                    let path = UnsafePointer(cargs[0]!)
                    cargs.withUnsafeBytes { raw in
                        execv(
                            path,
                            raw.baseAddress!.assumingMemoryBound(to: (UnsafeMutablePointer<CChar>?).self),
                        )
                    }
                    _exit(127)
                }
                guard pid > 0 else { return nil }
                return (pid, master)
            #elseif os(Linux)
                var master: Int32 = -1
                var slave: Int32 = -1
                var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
                guard openpty(&master, &slave, nil, nil, &ws) == 0 else { return nil }
                let pid = Glibc.fork()
                if pid == 0 {
                    _ = setsid()
                    _ = ioctl(slave, UInt(TIOCSCTTY), 0)
                    _ = dup2(slave, 0)
                    _ = dup2(slave, 1)
                    _ = dup2(slave, 2)
                    if master >= 0 { close(master) }
                    if slave >= 0 { close(slave) }
                    let path = UnsafePointer(cargs[0]!)
                    cargs.withUnsafeBytes { raw in
                        execv(
                            path,
                            raw.baseAddress!.assumingMemoryBound(to: (UnsafeMutablePointer<CChar>?).self),
                        )
                    }
                    _exit(127)
                }
                close(slave)
                guard pid > 0 else {
                    close(master)
                    return nil
                }
                return (pid, master)
            #endif
        }

        // MARK: - Loops

        private func readLoop(_ fd: Int32) {
            let capacity = 8_192
            var buffer = [UInt8](repeating: 0, count: capacity)
            while true {
                lock.lock()
                let live = !finished
                lock.unlock()
                guard live else { break }
                let n = buffer.withUnsafeMutableBytes { p in
                    read(fd, p.baseAddress!.assumingMemoryBound(to: CChar.self), capacity)
                }
                if n > 0 {
                    lock.lock()
                    let handler = onData
                    let stillLive = !finished
                    lock.unlock()
                    if stillLive { handler?(Array(buffer[0 ..< n])) }
                    continue
                }
                if n < 0, errno == EINTR { continue }
                break // EOF or EIO — the child's write end is gone
            }
            finishSide(read: true)
        }

        private func reapLoop(_ pid: pid_t) {
            var status: Int32 = 0
            let code: Int32 = {
                while waitpid(pid, &status, 0) < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if status & 0x7F == 0 { return status >> 8 }
                return 128 + (status & 0x7F)
            }()
            lock.lock()
            if exitCode == -1 { exitCode = code }
            lock.unlock()
            finishSide(read: false)
        }

        /// Fires `onExit` exactly once, after the read loop ended and the child
        /// was reaped. Closes the master fd on that final transition only.
        private func finishSide(read readEnded: Bool) {
            lock.lock()
            if readEnded { readDone = true } else { reapDone = true }
            guard readDone, reapDone, !finished else {
                lock.unlock()
                return
            }
            finished = true
            let code = exitCode
            let handler = onExit
            let mfd = masterFD
            masterFD = -1
            lock.unlock()
            if mfd >= 0 { close(mfd) }
            handler?(code)
        }
    }
#endif
