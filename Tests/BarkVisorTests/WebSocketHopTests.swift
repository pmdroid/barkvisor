import Dispatch
import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home console hop (PAS-224)", .serialized)
struct WebSocketHopTests {
    private static let ticket = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @Test func `dial failure closes inbound`() async {
        let inbound = FakeHopPeer()
        await WebSocketHop.run(inbound: inbound, farEnd: FailingHopFarEnd())
        #expect(inbound.isClosed)
    }

    @Test func `hop target omits query credentials`() throws {
        let url = try #require(
            URL(string: "ws://127.0.0.1:7777/api/vms/vm-1/vnc?ticket=secret&session=home"),
        )
        #expect(WebSocketHop.safeHopTarget(url) == "ws://127.0.0.1:7777/api/vms/vm-1/vnc")
    }

    @Test func `inbound closed before dial completes closes the far end`() async throws {
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        let farEnd = DelayedHopFarEnd(peer: remote)
        let task = Task {
            await WebSocketHop.run(inbound: inbound, farEnd: farEnd)
        }
        try await waitUntil { inbound.hasCapture }
        inbound.close()
        farEnd.release()
        await task.value
        try await waitUntil { remote.isClosed }
        #expect(remote.isClosed)
    }

    @Test func `pre-attach frames flush in order both ways`() async throws {
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        let farEnd = DelayedHopFarEnd(peer: remote)
        let task = Task {
            await WebSocketHop.run(inbound: inbound, farEnd: farEnd)
        }
        try await waitUntil { inbound.hasCapture }
        inbound.inject(.text("ping"))
        inbound.inject(.binary(byteBuffer("rfb")))
        farEnd.release()
        await task.value
        let expected = ["text:ping", "binary:rfb"]
        try await waitUntil { remote.sentLabels() == expected }
        #expect(remote.sentLabels() == expected)
    }

    @Test func `server-first banner reaches the client in order`() async throws {
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        await WebSocketHop.run(
            inbound: inbound,
            farEnd: BannerHopFarEnd(
                peer: remote,
                banners: [.text("RFB 003.008\n"), .binary(byteBuffer("sec"))],
            ),
        )
        let expected = ["text:RFB 003.008\n", "binary:sec"]
        try await waitUntil { inbound.sentLabels() == expected }
        #expect(inbound.sentLabels() == expected)
    }

    @Test func `overflow toward remote closes both ends`() async throws {
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        let farEnd = DelayedHopFarEnd(peer: remote)
        let task = Task {
            await WebSocketHop.run(inbound: inbound, farEnd: farEnd, maxPendingBytes: 8)
        }
        try await waitUntil { inbound.hasCapture }
        inbound.inject(.text("123456789"))
        farEnd.release()
        await task.value
        #expect(inbound.isClosed)
        #expect(remote.isClosed)
    }

    @Test func `overflow toward client closes both ends`() async {
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        await WebSocketHop.run(
            inbound: inbound,
            farEnd: BannerHopFarEnd(peer: remote, banner: .text("123456789")),
            maxPendingBytes: 8,
        )
        #expect(inbound.isClosed)
        #expect(remote.isClosed)
    }

    @Test func `live overflow after attach closes both ends`() {
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        let flag = OverflowFlag()
        let toRemote = WebSocketPipeBox()
        toRemote.maxPendingBytes = 8
        toRemote.onOverflow = { flag.fired = true }
        inbound.capture(into: toRemote)
        toRemote.attach(remote)
        inbound.inject(.text("123456789"))
        #expect(flag.fired)
        #expect(inbound.isClosed)
        #expect(toRemote.overflowed)
        remote.close()
    }

    @Test func `default cap holds a one-megabyte VNC banner`() async {
        var buffer = ByteBufferAllocator().buffer(capacity: 1_000_000)
        buffer.writeRepeatingByte(0x41, count: 1_000_000)
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        await WebSocketHop.run(
            inbound: inbound,
            farEnd: BannerHopFarEnd(peer: remote, banner: .binary(buffer)),
        )
        #expect(!inbound.isClosed)
        #expect(!remote.isClosed)
        #expect(inbound.sentBinaryByteCount() == 1_000_000)
    }

    @Test func `unix socket close closes the client`() async throws {
        let fixture = try await UnixHopFixture.make()
        defer { fixture.shutdown() }
        let inbound = FakeHopPeer()
        let task = Task {
            await WebSocketHop.run(inbound: inbound, unixSocketPath: fixture.path)
        }
        let accepted = try await fixture.takeAccepted()
        accepted.close(promise: nil)
        try await waitUntil { inbound.isClosed }
        await task.value
        #expect(inbound.isClosed)
    }

    @Test func `unix hop splits a 40 KiB read under the 16 KiB WS frame cap`() async throws {
        let fixture = try await UnixHopFixture.make()
        defer { fixture.shutdown() }
        let inbound = FakeHopPeer()
        let task = Task {
            await WebSocketHop.run(inbound: inbound, unixSocketPath: fixture.path)
        }
        let accepted = try await fixture.takeAccepted()
        var payload = ByteBufferAllocator().buffer(capacity: 40_000)
        payload.writeRepeatingByte(0x5A, count: 40_000)
        accepted.writeAndFlush(payload, promise: nil)
        try await waitUntil { inbound.sentBinaryByteCount() == 40_000 }
        let sizes = inbound.sentBinarySizes()
        #expect(!sizes.isEmpty)
        #expect(sizes.allSatisfy { $0 <= WebSocketHop.maxBinaryFrameBytes })
        #expect(sizes.reduce(0, +) == 40_000)
        inbound.close()
        await task.value
    }

    @Test func `client close closes the unix socket`() async throws {
        let fixture = try await UnixHopFixture.make()
        defer { fixture.shutdown() }
        let inbound = FakeHopPeer()
        let task = Task {
            await WebSocketHop.run(inbound: inbound, unixSocketPath: fixture.path)
        }
        let accepted = try await fixture.takeAccepted()
        inbound.close()
        try await waitUntil { !accepted.isActive }
        await task.value
        #expect(!accepted.isActive)
    }

    @Test func `agent hop uses the QEMU unix socket when vmState is set`() async throws {
        let fixture = try await UnixHopFixture.make()
        defer { fixture.shutdown() }
        let inbound = FakeHopPeer()
        let proxy = AgentLocalProxyController(vmState: FakeVMState(vncPath: fixture.path))
        let task = Task {
            await proxy.tunnel(inbound: inbound, vmID: "vm-9", kind: .vnc, query: "ticket=\(Self.ticket)")
        }
        let accepted = try await fixture.takeAccepted()
        inbound.inject(.binary(byteBuffer("rfb")))
        try await waitUntil { accepted.isActive }
        inbound.close()
        try await waitUntil { !accepted.isActive }
        await task.value
        #expect(!accepted.isActive)
    }

    @Test func `agent hop uses injected dialer on the shared group`() async throws {
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        let dialer = RecordingHomeWebSocketDialer(peer: remote)
        let proxy = AgentLocalProxyController(localPort: 7_777, dialer: dialer)
        await proxy.tunnel(
            inbound: inbound,
            vmID: "vm-9",
            kind: .vnc,
            query: "ticket=\(Self.ticket)&session=home-session",
        )
        #expect(dialer.urls.count == 1)
        let url = try #require(dialer.urls.first)
        #expect(url.scheme == "ws")
        #expect(url.path == "/api/vms/vm-9/vnc")
        #expect(url.query == "ticket=\(Self.ticket)")
        #expect(dialer.usedSingleton)
        inbound.inject(.text("frame"))
        try await waitUntil { remote.sentTexts() == ["frame"] }
        #expect(remote.sentTexts() == ["frame"])
    }

    @Test func `this Device console hop uses injected dialer`() async throws {
        let inbound = FakeHopPeer()
        let remote = FakeHopPeer()
        let dialer = RecordingHomeWebSocketDialer(peer: remote)
        let url = try HomeDeviceProxy.consoleTargetURL(
            HomeConsoleTarget(
                isSelf: true,
                localPort: 7_777,
                agentHost: nil,
                agentPort: 7_777,
                vmID: "vm-local",
                kind: .console,
                query: "ticket=\(Self.ticket)",
            ),
        )
        await WebSocketHop.run(inbound: inbound, url: url, dialer: dialer)
        #expect(dialer.urls.first?.path == "/api/vms/vm-local/console")
        #expect(dialer.usedSingleton)
        inbound.inject(.text("hi"))
        try await waitUntil { remote.sentTexts() == ["hi"] }
        #expect(remote.sentTexts() == ["hi"])
    }
}

private func byteBuffer(_ text: String) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    return buffer
}

private func waitUntil(
    _ predicate: @escaping @Sendable () -> Bool,
    nanoseconds: UInt64 = 2_000_000_000,
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds
    while !predicate() {
        if DispatchTime.now().uptimeNanoseconds > deadline {
            throw BarkVisorError.timeout("hop seam")
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

private final class FakeHopPeer: WebSocketHopPeer, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var box: WebSocketPipeBox?
    private var sent: [WebSocketPipeBox.Frame] = []
    private let closePromise: EventLoopPromise<Void>

    init(eventLoop: any EventLoop = MultiThreadedEventLoopGroup.singleton.next()) {
        closePromise = eventLoop.makePromise(of: Void.self)
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    var hasCapture: Bool {
        lock.lock()
        defer { lock.unlock() }
        return box != nil
    }

    var closeFuture: EventLoopFuture<Void> {
        closePromise.futureResult
    }

    func send(_ frame: WebSocketPipeBox.Frame, completed: (@Sendable () -> Void)?) {
        lock.lock()
        if !closed {
            sent.append(frame)
        }
        lock.unlock()
        completed?()
    }

    func capture(into box: WebSocketPipeBox) {
        lock.lock()
        self.box = box
        lock.unlock()
    }

    func close() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        if !already {
            closePromise.succeed(())
        }
    }

    func inject(_ frame: WebSocketPipeBox.Frame) {
        let box: WebSocketPipeBox? = {
            lock.lock()
            defer { lock.unlock() }
            return self.box
        }()
        if let box, !box.sendOrBuffer(frame) {
            close()
        }
    }

    func sentTexts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent.compactMap { frame in
            if case let .text(text) = frame { return text }
            return nil
        }
    }

    func sentBinaryStrings() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent.compactMap { frame in
            if case let .binary(buffer) = frame { return String(buffer: buffer) }
            return nil
        }
    }

    func sentBinarySizes() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sent.compactMap { frame in
            if case let .binary(buffer) = frame { return buffer.readableBytes }
            return nil
        }
    }

    func sentBinaryByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sent.reduce(0) { count, frame in
            if case let .binary(buffer) = frame { return count + buffer.readableBytes }
            return count
        }
    }

    func sentLabels() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent.map { frame in
            switch frame {
            case let .text(text): "text:\(text)"
            case let .binary(buffer): "binary:\(String(buffer: buffer))"
            }
        }
    }
}

private struct FailingHopFarEnd: WebSocketHopFarEnding {
    func open(
        configure _: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        throw BarkVisorError.timeout("Device console did not answer")
    }
}

private final class DelayedHopFarEnd: WebSocketHopFarEnding, @unchecked Sendable {
    let peer: FakeHopPeer
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(peer: FakeHopPeer) {
        self.peer = peer
    }

    func release() {
        lock.lock()
        released = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func open(
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
        configure(peer)
        return peer
    }
}

private struct BannerHopFarEnd: WebSocketHopFarEnding {
    let peer: FakeHopPeer
    let banners: [WebSocketPipeBox.Frame]

    init(peer: FakeHopPeer, banner: WebSocketPipeBox.Frame) {
        self.peer = peer
        banners = [banner]
    }

    init(peer: FakeHopPeer, banners: [WebSocketPipeBox.Frame]) {
        self.peer = peer
        self.banners = banners
    }

    func open(
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        configure(peer)
        for banner in banners {
            peer.inject(banner)
        }
        return peer
    }
}

private final class RecordingHomeWebSocketDialer: HomeWebSocketDialing, @unchecked Sendable {
    private let lock = NSLock()
    private let peer: FakeHopPeer
    private(set) var urls: [URL] = []
    private(set) var usedSingleton = false

    init(peer: FakeHopPeer) {
        self.peer = peer
    }

    func connect(
        url: URL,
        on eventLoopGroup: EventLoopGroup,
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        record(url: url, eventLoopGroup: eventLoopGroup)
        configure(peer)
        return peer
    }

    private func record(url: URL, eventLoopGroup: EventLoopGroup) {
        lock.lock()
        urls.append(url)
        usedSingleton = (eventLoopGroup as AnyObject) === MultiThreadedEventLoopGroup.singleton
        lock.unlock()
    }
}

private final class UnixAcceptBox: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var accepted: Channel?
    private var waiter: CheckedContinuation<Channel, Error>?

    func offer(_ channel: Channel) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: channel)
            return
        }
        accepted = channel
        lock.unlock()
    }

    func take() async throws -> Channel {
        try await withThrowingTaskGroup(of: Channel.self) { group in
            group.addTask { try await self.takeOnce() }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw BarkVisorError.timeout("unix accept")
            }
            guard let channel = try await group.next() else {
                throw BarkVisorError.timeout("unix accept")
            }
            group.cancelAll()
            return channel
        }
    }

    private func takeOnce() async throws -> Channel {
        if let accepted = takeIfReady() {
            return accepted
        }
        return try await withCheckedThrowingContinuation { cont in
            park(cont)
        }
    }

    private func takeIfReady() -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        if let accepted {
            self.accepted = nil
            return accepted
        }
        return nil
    }

    private func park(_ cont: CheckedContinuation<Channel, Error>) {
        lock.lock()
        if let accepted {
            self.accepted = nil
            lock.unlock()
            cont.resume(returning: accepted)
            return
        }
        waiter = cont
        lock.unlock()
    }

    func channelActive(context: ChannelHandlerContext) {
        offer(context.channel)
    }
}

private final class OverflowFlag: @unchecked Sendable {
    var fired = false
}

private struct FakeVMState: VMStateQuerying {
    var vncPath: String?
    var serialPath: String?

    func isRunning(_: String) async -> Bool {
        vncPath != nil || serialPath != nil
    }
    func isActiveOrStarting(_: String) async -> Bool {
        true
    }
    func allRunningVMs() async -> [String: RunningVM] {
        [:]
    }
    func vncSocketPath(for _: String) async -> String? {
        vncPath
    }
    func serialSocketPath(for _: String) async -> String? {
        serialPath
    }
    func qmpSocketPath(for _: String) async -> String? {
        nil
    }
}

private struct UnixHopFixture {
    let path: String
    let dir: URL
    let server: Channel
    let accept: UnixAcceptBox

    static func make() async throws -> UnixHopFixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hop-unix-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("vnc.sock").path
        let accept = UnixAcceptBox()
        let server = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Channel, Error>) in
            ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(accept)
                }
                .bind(unixDomainSocketPath: path)
                .whenComplete { result in
                    cont.resume(with: result)
                }
        }
        return UnixHopFixture(path: path, dir: dir, server: server, accept: accept)
    }

    func takeAccepted() async throws -> Channel {
        try await accept.take()
    }

    func shutdown() {
        server.close(promise: nil)
        try? FileManager.default.removeItem(at: dir)
    }
}
