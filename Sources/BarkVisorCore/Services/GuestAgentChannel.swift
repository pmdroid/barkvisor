import Foundation

/// qemu-guest-agent transport helpers (PAS-239).
///
/// `QMPClient` is the socket. This type owns the `guest-sync` handshake used by
/// inventory collect and graceful `guest-shutdown`.
public enum GuestAgentChannel {
    /// Connect to the guest-agent unix socket and run `guest-sync`.
    public static func connect(
        socketPath: String,
        connectTimeoutSeconds: Int = 2,
        clientTimeoutSeconds: Int = 3,
    ) throws -> QMPClient {
        let client = QMPClient(socketPath: socketPath, timeoutSeconds: clientTimeoutSeconds)
        do {
            try client.connectRaw(timeoutSeconds: connectTimeoutSeconds)
            try handshake(client)
        } catch {
            client.disconnect()
            throw error
        }
        return client
    }

    /// `guest-sync` must echo the supplied id. Missing `return` is tolerated
    /// (same as the previous shutdown path).
    public static func handshake(_ client: QMPClient) throws {
        let syncId = Int.random(in: 1 ... 999_999)
        let sync = try client.executeWithArgs("guest-sync", args: ["id": syncId])
        try validateGuestSync(sync, expected: syncId)
    }

    public static func validateGuestSync(_ response: [String: Any], expected: Int) throws {
        if let ret = jsonInt(response["return"]), ret != expected {
            throw BarkVisorError.monitorError(
                "guest-sync mismatch (expected \(expected), got \(ret))",
            )
        }
    }

    /// Issue `guest-shutdown` over the guest-agent channel.
    /// A closed connection after a successful write is treated as success (guest is dying).
    public static func shutdown(socketPath: String) throws {
        let ga = QMPClient(socketPath: socketPath, timeoutSeconds: 5)
        try ga.connectRaw(timeoutSeconds: 2)
        defer { ga.disconnect() }
        try handshake(ga)

        do {
            _ = try ga.executeWithArgs("guest-shutdown", args: ["mode": "powerdown"])
        } catch {
            let msg = String(describing: error)
            if msg.contains("closed") || msg.contains("empty read") || msg.contains("timed out") {
                return
            }
            throw error
        }
    }

    /// Best-effort guest file read (coding-session git stamp). Nil on any failure.
    public static func readTextFile(socketPath: String, path: String, maxBytes: Int = 256) -> String? {
        let client: QMPClient
        do {
            client = try connect(socketPath: socketPath, connectTimeoutSeconds: 1, clientTimeoutSeconds: 2)
        } catch {
            return nil
        }
        defer { client.disconnect() }
        guard let opened = try? client.executeWithArgs(
            "guest-file-open",
            args: ["path": path, "mode": "r"],
        ),
            let handle = jsonInt(opened["return"])
        else { return nil }
        defer {
            _ = try? client.executeWithArgs("guest-file-close", args: ["handle": handle])
        }
        guard let read = try? client.executeWithArgs(
            "guest-file-read",
            args: ["handle": handle, "count": maxBytes],
        ),
            let body = read["return"] as? [String: Any],
            let b64 = body["buf-b64"] as? String,
            let data = Data(base64Encoded: b64),
            data.count <= maxBytes
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func jsonInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let i = value as? Int64 { return Int(i) }
        if let i = value as? UInt64 { return Int(i) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}
