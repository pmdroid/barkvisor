import BarkVisorHelperProtocol
import Foundation
import os

public struct BridgeStateDTO: Codable, Sendable {
    public let interface: String
    public let socketPath: String?
    public let plistExists: Bool
    public let daemonRunning: Bool
    public let status: String

    public init(
        interface: String,
        socketPath: String?,
        plistExists: Bool,
        daemonRunning: Bool,
        status: String,
    ) {
        self.interface = interface
        self.socketPath = socketPath
        self.plistExists = plistExists
        self.daemonRunning = daemonRunning
        self.status = status
    }
}

public actor HelperXPCClient {
    public static let shared = HelperXPCClient()

    private static let xpcTimeout: UInt64 = 5_000_000_000 // 5 seconds

    private var connection: NSXPCConnection?

    private func getConnection() -> NSXPCConnection {
        if let conn = connection { return conn }
        let conn = NSXPCConnection(
            machServiceName: kHelperMachServiceName,
            options: .privileged,
        )
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.interruptionHandler = { @Sendable [weak self] in
            NSLog("BarkVisorHelper: XPC connection interrupted")
            Task { await self?.resetConnection() }
        }
        conn.invalidationHandler = { @Sendable [weak self] in
            NSLog("BarkVisorHelper: XPC connection invalidated")
            Task { await self?.resetConnection() }
        }
        conn.resume()
        connection = conn
        return conn
    }

    private func resetConnection() {
        connection = nil
    }

    /// Wrap an XPC call with a timeout so a hung connection can't block forever.
    private func withXPCTimeout<T: Sendable>(
        seconds: UInt64 = HelperXPCClient.xpcTimeout,
        _ body: @Sendable @escaping (CheckedContinuation<T, any Error>) -> Void,
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    body(cont)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds)
                throw XPCTimeoutError()
            }
            guard let result = try await group.next() else {
                throw XPCTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - XPC Call Helpers

    /// Call a helper method that returns a value.
    private func call<T: Sendable>(
        timeout: UInt64 = HelperXPCClient.xpcTimeout,
        _ block: @Sendable @escaping (any HelperProtocol, @escaping @Sendable (T) -> Void) -> Void,
    ) async throws -> T {
        nonisolated(unsafe) let conn = getConnection()
        return try await withXPCTimeout(seconds: timeout) { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                guard resumed.withLock({
                    let old = $0
                    $0 = true
                    return !old
                })
                else { return }
                cont.resume(throwing: error)
            }
            guard let p = proxy as? (any HelperProtocol) else {
                guard resumed.withLock({
                    let old = $0
                    $0 = true
                    return !old
                })
                else { return }
                cont.resume(throwing: XPCProxyError())
                return
            }
            block(p) { value in
                guard resumed.withLock({
                    let old = $0
                    $0 = true
                    return !old
                })
                else { return }
                cont.resume(returning: value)
            }
        }
    }

    /// Call a helper method that returns (Bool, String?) success/error.
    private func callBridge(
        timeout: UInt64 = 15_000_000_000,
        _ block:
        @Sendable @escaping (any HelperProtocol, @escaping @Sendable (Bool, String?) -> Void) -> Void,
    ) async throws {
        nonisolated(unsafe) let conn = getConnection()
        try await withXPCTimeout(seconds: timeout) { (cont: CheckedContinuation<Void, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                guard resumed.withLock({
                    let old = $0
                    $0 = true
                    return !old
                })
                else { return }
                cont.resume(throwing: error)
            }
            guard let p = proxy as? (any HelperProtocol) else {
                guard resumed.withLock({
                    let old = $0
                    $0 = true
                    return !old
                })
                else { return }
                cont.resume(throwing: XPCProxyError())
                return
            }
            block(p) { ok, err in
                guard resumed.withLock({
                    let old = $0
                    $0 = true
                    return !old
                })
                else { return }
                if ok {
                    cont.resume()
                } else {
                    cont.resume(
                        throwing: NSError(
                            domain: "BarkVisor",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: err ?? "Unknown error"],
                        ),
                    )
                }
            }
        }
    }

    // MARK: - Basic

    public func getVersion() async throws -> String {
        try await call { $0.getVersion(reply: $1) }
    }

    public func ping() async throws -> String {
        try await call { $0.ping(reply: $1) }
    }

    // MARK: - Bridge Management

    public func installBridge(interface: String) async throws {
        try await callBridge { $0.installBridge(interface: interface, reply: $1) }
    }

    public func removeBridge(interface: String) async throws {
        try await callBridge { $0.removeBridge(interface: interface, reply: $1) }
    }

    public func startBridge(interface: String) async throws {
        try await callBridge { $0.startBridge(interface: interface, reply: $1) }
    }

    public func stopBridge(interface: String) async throws {
        try await callBridge { $0.stopBridge(interface: interface, reply: $1) }
    }

    // MARK: - Software Update

    public func installUpdate(packagePath: String, expectedVersion: String) async throws {
        try await callBridge(timeout: 300_000_000_000) { // 5 min timeout
            $0.installUpdate(packagePath: packagePath, expectedVersion: expectedVersion, reply: $1)
        }
    }

    // MARK: - All Bridge States

    public func getAllBridgeStates() async throws -> [BridgeStateDTO] {
        let json: String = try await call { $0.getAllBridgeStates(reply: $1) }
        return try JSONDecoder().decode([BridgeStateDTO].self, from: Data(json.utf8))
    }

    /// Returns a status string: "running", "installed", or "not_installed".
    public func bridgeStatus(interface: String) async throws -> String {
        try await call { proxy, reply in
            proxy.bridgeStatus(interface: interface) { _, status in
                reply(status ?? "unknown")
            }
        }
    }
}

public struct XPCTimeoutError: Error, LocalizedError, Sendable {
    public var errorDescription: String? {
        "XPC call timed out"
    }

    public init() {}
}

public struct XPCProxyError: Error, LocalizedError, Sendable {
    public var errorDescription: String? {
        "Failed to obtain XPC remote object proxy"
    }

    public init() {}
}
