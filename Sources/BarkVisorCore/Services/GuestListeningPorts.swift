import Foundation

/// TCP LISTEN snapshot from qemu-guest-agent (PAS-225).
///
/// `null` on the API means unavailable; `[]` means the guest reported none.
/// Only TCP. Loopback is `scope: internal` and never becomes a URL.
public struct GuestListeningPortDTO: Codable, Sendable, Equatable, Hashable {
    public let proto: String
    public let address: String
    public let port: Int
    public let scope: String
    public let label: String?
    /// `http` / `https` when the listener should open in a browser; nil otherwise.
    public let scheme: String?

    public init(
        proto: String = "tcp",
        address: String,
        port: Int,
        scope: String,
        label: String?,
        scheme: String? = nil,
    ) {
        self.proto = proto
        self.address = address
        self.port = port
        self.scope = scope
        self.label = label
        self.scheme = scheme
    }
}

public enum GuestListeningPorts {
    public static let collectIntervalSeconds: TimeInterval = 30
    public static let collectFailureBackoffSeconds: TimeInterval = 300

    public static let scopeInternal = "internal"
    public static let scopeNetwork = "network"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastAttempt: [String: Date] = [:]
    private nonisolated(unsafe) static var lastFailed: [String: Bool] = [:]

    public static func shouldCollect(
        vmID: String,
        now: Date = Date(),
        interval: TimeInterval? = nil,
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wait = interval ?? (lastFailed[vmID] == true
            ? collectFailureBackoffSeconds
            : collectIntervalSeconds)
        if let last = lastAttempt[vmID], now.timeIntervalSince(last) < wait {
            return false
        }
        return true
    }

    public static func markCollected(vmID: String, now: Date = Date(), succeeded: Bool = true) {
        lock.lock()
        lastAttempt[vmID] = now
        lastFailed[vmID] = !succeeded
        lock.unlock()
    }

    public static func clearAttempt(vmID: String) {
        lock.lock()
        lastAttempt.removeValue(forKey: vmID)
        lastFailed.removeValue(forKey: vmID)
        lock.unlock()
    }

    /// SSH, common HTTP/HTTPS, typical dev servers, DBs, RDP, VNC.
    public static let publishedPorts: Set<Int> = [
        22, 80, 443,
        3_000, 3_001, 4_173, 4_200, 5_000, 5_173, 5_174,
        8_000, 8_080, 8_081, 8_443, 8_888,
        3_306, 5_432, 6_379, 27_017,
        3_389, 5_900,
    ]

    public static func isPublishedPort(_ port: Int) -> Bool {
        publishedPorts.contains(port)
    }

    public static func label(for port: Int) -> String? {
        switch port {
        case 22: "SSH"
        case 80, 8_000, 8_080: "HTTP"
        case 443, 8_443: "HTTPS"
        case 3_000, 3_001, 4_173, 4_200, 5_000, 5_173, 5_174, 8_081, 8_888: "Dev"
        case 3_306: "MySQL"
        case 5_432: "Postgres"
        case 6_379: "Redis"
        case 27_017: "Mongo"
        case 3_389: "RDP"
        case 5_900: "VNC"
        default: nil
        }
    }

    public static func impliedScheme(for port: Int) -> String? {
        switch port {
        case 80, 3_000, 3_001, 4_173, 4_200, 5_000, 5_173, 5_174, 8_000, 8_080, 8_081, 8_888:
            "http"
        case 443, 8_443:
            "https"
        default:
            nil
        }
    }

    public static func isNonHTTPService(_ port: Int) -> Bool {
        switch port {
        case 22, 3_306, 3_389, 5_432, 5_900, 6_379, 27_017: true
        default: false
        }
    }

    public static func isHTTPProbeCandidate(_ port: Int) -> Bool {
        isPublishedPort(port) && !isNonHTTPService(port) && impliedScheme(for: port) != "https"
    }

    public static func selectPublished(_ ports: [GuestListeningPortDTO]) -> [GuestListeningPortDTO] {
        canonicalize(ports.filter { isPublishedPort($0.port) })
    }

    public static func applyHTTPSchemes(
        _ ports: [GuestListeningPortDTO],
        probedHTTP: Set<Int>,
        probeRan: Bool,
    ) -> [GuestListeningPortDTO] {
        canonicalize(ports.map { item in
            let scheme = resolvedScheme(port: item.port, probedHTTP: probedHTTP, probeRan: probeRan)
            let labeled = item.label ?? (
                scheme == "http" ? "HTTP" : scheme == "https" ? "HTTPS" : nil
            )
            return GuestListeningPortDTO(
                proto: item.proto,
                address: item.address,
                port: item.port,
                scope: item.scope,
                label: labeled,
                scheme: scheme,
            )
        })
    }

    static func resolvedScheme(port: Int, probedHTTP: Set<Int>, probeRan: Bool) -> String? {
        if isNonHTTPService(port) { return nil }
        if probedHTTP.contains(port) {
            return impliedScheme(for: port) == "https" ? "https" : "http"
        }
        if probeRan {
            return impliedScheme(for: port) == "https" ? "https" : nil
        }
        return impliedScheme(for: port)
    }

    public static func isLoopbackAddress(_ address: String) -> Bool {
        let host = normalizeAddress(address)
        if host == "localhost" || host == "::1" { return true }
        if host.hasPrefix("127.") { return true }
        return false
    }

    public static func isWildcardAddress(_ address: String) -> Bool {
        let host = normalizeAddress(address)
        return host == "0.0.0.0" || host == "*" || host == "::" || host.isEmpty
    }

    public static func scope(for address: String) -> String {
        isLoopbackAddress(address) ? scopeInternal : scopeNetwork
    }

    public static func makePort(address: String, port: Int) -> GuestListeningPortDTO? {
        guard port > 0, port <= 65_535 else { return nil }
        let host = normalizeAddress(address)
        return GuestListeningPortDTO(
            proto: "tcp",
            address: host,
            port: port,
            scope: scope(for: host),
            label: label(for: port),
            scheme: impliedScheme(for: port),
        )
    }

    public static func canonicalize(_ ports: [GuestListeningPortDTO]) -> [GuestListeningPortDTO] {
        var seen = Set<String>()
        var unique: [GuestListeningPortDTO] = []
        for port in ports {
            let key = "\(port.proto)|\(normalizeAddress(port.address))|\(port.port)"
            if seen.insert(key).inserted {
                unique.append(port)
            }
        }
        return unique.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.address < $1.address
        }
    }

    public static func encodeJSON(_ ports: [GuestListeningPortDTO]) -> String? {
        JSONColumnCoding.encode(canonicalize(ports))
    }

    /// Keep the previous snapshot when the collected set is unchanged.
    public static func persistFields(
        collected: [GuestListeningPortDTO]?,
        previousJSON: String?,
        previousCollectedAt: String?,
        now: String,
    ) -> (json: String?, collectedAt: String?) {
        guard let collected else {
            return (previousJSON, previousCollectedAt)
        }
        let next = canonicalize(collected)
        if let previousJSON,
           let previous = JSONColumnCoding.decodeArray(GuestListeningPortDTO.self, from: previousJSON),
           canonicalize(previous) == next {
            return (previousJSON, previousCollectedAt)
        }
        return (encodeJSON(next), now)
    }

    public static func parseCommandOutput(_ text: String) -> [GuestListeningPortDTO] {
        var ports: [GuestListeningPortDTO] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if let port = parseListenLine(line) {
                ports.append(port)
            }
        }
        return canonicalize(ports)
    }

    public static func parseProcNet(tcp: String, tcp6: String? = nil) -> [GuestListeningPortDTO] {
        var ports: [GuestListeningPortDTO] = []
        ports.append(contentsOf: parseProcNetTable(tcp, ipv6: false))
        if let tcp6 {
            ports.append(contentsOf: parseProcNetTable(tcp6, ipv6: true))
        }
        return canonicalize(ports)
    }

    static func collect(using client: QMPClient) -> [GuestListeningPortDTO]? {
        let raw: [GuestListeningPortDTO]
        if let text = execCapture(
            client,
            path: "/bin/sh",
            arg: ["-c", "(ss -lntH || ss -lnt || netstat -lnt) 2>/dev/null"],
        ) {
            raw = parseCommandOutput(text)
        } else if let text = firstExec(
            client,
            paths: ["/usr/bin/ss", "/bin/ss", "/usr/sbin/ss"],
            arg: ["-lntH"],
        ) {
            raw = parseCommandOutput(text)
        } else if let text = firstExec(
            client,
            paths: ["/usr/bin/netstat", "/bin/netstat"],
            arg: ["-lnt"],
        ) {
            raw = parseCommandOutput(text)
        } else if let tcp = readGuestFile(client, path: "/proc/net/tcp") {
            raw = parseProcNet(tcp: tcp, tcp6: readGuestFile(client, path: "/proc/net/tcp6"))
        } else {
            return nil
        }
        return decoratePublished(raw, using: client)
    }

    static func decoratePublished(
        _ ports: [GuestListeningPortDTO],
        using client: QMPClient,
    ) -> [GuestListeningPortDTO] {
        let visible = selectPublished(ports)
        let candidates = visible.map(\.port).filter(isHTTPProbeCandidate)
        guard !candidates.isEmpty else {
            return applyHTTPSchemes(visible, probedHTTP: [], probeRan: false)
        }
        if let probed = probeHTTPPorts(Set(candidates).sorted(), using: client) {
            return applyHTTPSchemes(visible, probedHTTP: probed, probeRan: true)
        }
        return applyHTTPSchemes(visible, probedHTTP: [], probeRan: false)
    }

    static func probeHTTPPorts(_ ports: [Int], using client: QMPClient) -> Set<Int>? {
        guard !ports.isEmpty else { return [] }
        let list = ports.map(String.init).joined(separator: " ")
        let script = """
        python3 -c "import socket,sys
        for p in sys.argv[1:]:
         n=int(p)
         hit=False
         for host in ('127.0.0.1','::1'):
          try:
           s=socket.create_connection((host,n),0.2); s.settimeout(0.2)
           s.sendall(b'HEAD / HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n')
           d=s.recv(32); s.close()
           if d.startswith(b'HTTP/'):
            print(p); hit=True; break
          except Exception:
           pass
         if hit: pass
        " \(list) 2>/dev/null
        """
        guard let text = execCapture(client, path: "/bin/sh", arg: ["-c", script]) else {
            return nil
        }
        return Set(
            text.split(whereSeparator: \.isWhitespace)
                .compactMap { Int($0) }
                .filter { ports.contains($0) },
        )
    }

    private static func firstExec(_ client: QMPClient, paths: [String], arg: [String]) -> String? {
        for path in paths {
            if let text = execCapture(client, path: path, arg: arg) {
                return text
            }
        }
        return nil
    }

    // MARK: - Parse helpers

    private static func parseListenLine(_ line: String) -> GuestListeningPortDTO? {
        guard !line.isEmpty else { return nil }
        let upper = line.uppercased()
        if upper.hasPrefix("STATE") || upper.hasPrefix("PROTO") || upper.hasPrefix("ACTIVE") {
            return nil
        }
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = fields.first else { return nil }
        let proto = first.lowercased()
        if proto.hasPrefix("udp") { return nil }
        if !upper.contains("LISTEN") { return nil }

        for field in fields {
            if looksLikeRemoteWildcard(field) { continue }
            if let parsed = parseEndpoint(field) {
                return makePort(address: parsed.address, port: parsed.port)
            }
        }
        return nil
    }

    private static func looksLikeRemoteWildcard(_ token: String) -> Bool {
        let t = token.lowercased()
        return t == "0.0.0.0:*" || t == "*:*" || t == "[::]:*" || t == ":::*"
    }

    private static func parseEndpoint(_ token: String) -> (address: String, port: Int)? {
        guard let colon = token.lastIndex(of: ":") else { return nil }
        let portStr = String(token[token.index(after: colon)...])
        guard let port = Int(portStr), port > 0, port <= 65_535 else { return nil }
        let host = String(token[..<colon])
        if host.contains("%") { return nil }
        return (normalizeAddress(host), port)
    }

    static func normalizeAddress(_ address: String) -> String {
        var host = address.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        if host == "*" || host.isEmpty { return "0.0.0.0" }
        return host.lowercased()
    }

    private static func parseProcNetTable(_ text: String, ipv6: Bool) -> [GuestListeningPortDTO] {
        var ports: [GuestListeningPortDTO] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.contains("local_address") { continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4 else { continue }
            let local = fields[1].contains(":") ? fields[1] : fields.count > 2 ? fields[2] : fields[1]
            let state = fields.count > 3 ? fields[3] : ""
            guard state.uppercased() == "0A" else { continue }
            guard let colon = local.lastIndex(of: ":") else { continue }
            let hexAddr = String(local[..<colon])
            let hexPort = String(local[local.index(after: colon)...])
            guard let port = Int(hexPort, radix: 16) else { continue }
            let address = ipv6 ? decodeIPv6Hex(hexAddr) : decodeIPv4Hex(hexAddr)
            guard let address, let item = makePort(address: address, port: port) else { continue }
            ports.append(item)
        }
        return ports
    }

    static func decodeIPv4Hex(_ hex: String) -> String? {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let b0 = value & 0xFF
        let b1 = (value >> 8) & 0xFF
        let b2 = (value >> 16) & 0xFF
        let b3 = (value >> 24) & 0xFF
        return "\(b0).\(b1).\(b2).\(b3)"
    }

    static func decodeIPv6Hex(_ hex: String) -> String? {
        let raw = hex.filter(\.isHexDigit)
        guard raw.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = raw.startIndex
        for _ in 0 ..< 4 {
            let wordEnd = raw.index(index, offsetBy: 8)
            let word = String(raw[index ..< wordEnd])
            guard let value = UInt32(word, radix: 16) else { return nil }
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
            index = wordEnd
        }
        return formatIPv6(bytes)
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "::" }
        var groups: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let value = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            groups.append(String(value, radix: 16))
        }
        return compressIPv6(groups)
    }

    private static func compressIPv6(_ groups: [String]) -> String {
        var bestStart = -1
        var bestLen = 0
        var i = 0
        while i < groups.count {
            if groups[i] == "0" {
                let start = i
                while i < groups.count, groups[i] == "0" {
                    i += 1
                }
                let len = i - start
                if len > bestLen {
                    bestStart = start
                    bestLen = len
                }
            } else {
                i += 1
            }
        }
        if bestLen < 2 {
            return groups.joined(separator: ":")
        }
        let head = groups[..<bestStart].joined(separator: ":")
        let tail = groups[(bestStart + bestLen)...].joined(separator: ":")
        if head.isEmpty, tail.isEmpty { return "::" }
        if head.isEmpty { return "::\(tail)" }
        if tail.isEmpty { return "\(head)::" }
        return "\(head)::\(tail)"
    }

    // MARK: - Guest agent I/O

    private static func execCapture(_ client: QMPClient, path: String, arg: [String]) -> String? {
        guard let result = try? client.executeWithArgs(
            "guest-exec",
            args: ["path": path, "arg": arg, "capture-output": true],
        ),
            let ret = result["return"] as? [String: Any],
            let pid = jsonInt(ret["pid"])
        else { return nil }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard let status = try? client.executeWithArgs("guest-exec-status", args: ["pid": pid]),
                  let body = status["return"] as? [String: Any]
            else { return nil }
            if body["exited"] as? Bool != true {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            let text = decodeBase64Text(body["out-data"] as? String)
            let code = jsonInt(body["exitcode"]) ?? 1
            if code == 0 { return text ?? "" }
            if let text, !text.isEmpty { return text }
            return nil
        }
        return nil
    }

    private static func readGuestFile(_ client: QMPClient, path: String) -> String? {
        guard let opened = try? client.executeWithArgs(
            "guest-file-open",
            args: ["path": path, "mode": "r"],
        ),
            let handle = jsonInt(opened["return"])
        else { return nil }
        defer {
            _ = try? client.executeWithArgs("guest-file-close", args: ["handle": handle])
        }

        var chunks = Data()
        for _ in 0 ..< 16 {
            guard let read = try? client.executeWithArgs(
                "guest-file-read",
                args: ["handle": handle, "count": 4_096],
            ),
                let body = read["return"] as? [String: Any]
            else { break }
            if let data = decodeBase64(body["buf-b64"] as? String) {
                chunks.append(data)
            }
            if body["eof"] as? Bool == true { break }
        }
        return String(data: chunks, encoding: .utf8)
    }

    private static func decodeBase64Text(_ value: String?) -> String? {
        guard let data = decodeBase64(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeBase64(_ value: String?) -> Data? {
        guard let value, !value.isEmpty else { return nil }
        return Data(base64Encoded: value)
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let i = value as? Int64 { return Int(i) }
        if let i = value as? UInt64 { return Int(i) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}
