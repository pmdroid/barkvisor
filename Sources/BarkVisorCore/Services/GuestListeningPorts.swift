import Foundation

/// TCP LISTEN snapshot from qemu-guest-agent (PAS-225, PAS-231).
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

// Windows netstat/PowerShell parsers plus the 3s collect budget sit in one type.
// swiftlint:disable type_body_length file_length
public enum GuestListeningPorts {
    public static let collectIntervalSeconds: TimeInterval = 30
    public static let collectFailureBackoffSeconds: TimeInterval = 300
    /// Shared wall-clock budget for ss/netstat attempts, /proc fallback, and HTTP probe.
    public static let collectTimeoutSeconds: TimeInterval = 3
    /// Decoded guest-exec `out-data` cap; oversized output is treated as unavailable.
    public static let execOutputMaxBytes = 65_536
    /// QMP JSON is larger than decoded out-data (base64). Fail before unbounded buffering.
    public static let execStatusMaxResponseBytes = 98_304

    public static let scopeInternal = "internal"
    public static let scopeNetwork = "network"

    private static let windowsPowerShellListenArgs = [
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "Get-NetTCPConnection -State Listen | ForEach-Object {"
            + " $_.LocalAddress + ' ' + $_.LocalPort + ' LISTEN' }",
    ]

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

    /// SSH, HTTP/S, typical self-host UIs, dev servers, DBs, RDP, VNC.
    public static let publishedPorts: Set<Int> = [
        22, 80, 81, 443,
        1_234, 1_880, 1_883, 2_283, 3_000, 3_001, 3_306, 3_389,
        4_173, 4_200, 5_000, 5_055, 5_173, 5_174, 5_432, 5_900, 6_379,
        6_767, 7_860, 7_878, 8_000, 8_006, 8_080, 8_081, 8_123, 8_188,
        8_384, 8_443, 8_686, 8_888, 8_883, 8_989, 9_000, 9_090, 9_091, 9_443, 9_696,
        11_434, 18_789, 27_017, 32_400,
    ]

    public static func isPublishedPort(_ port: Int) -> Bool {
        publishedPorts.contains(port)
    }

    public static func label(for port: Int) -> String? {
        switch port {
        case 22: "SSH"
        case 80, 8_000, 8_080: "HTTP"
        case 81: "NPM"
        case 443, 8_443, 9_443: "HTTPS"
        case 1_234: "LM Studio"
        case 1_880: "Node-RED"
        case 1_883, 8_883: "MQTT"
        case 2_283: "Immich"
        case 3_000, 3_001, 4_173, 4_200, 5_000, 5_173, 5_174, 8_081, 8_888: "Dev"
        case 3_306: "MySQL"
        case 3_389: "RDP"
        case 5_055: "Overseerr"
        case 5_432: "Postgres"
        case 5_900: "VNC"
        case 6_379: "Redis"
        case 6_767: "Bazarr"
        case 7_860: "Gradio"
        case 7_878: "Radarr"
        case 8_006: "Proxmox"
        case 8_123: "Home Assistant"
        case 8_188: "ComfyUI"
        case 8_384: "Syncthing"
        case 8_686: "Lidarr"
        case 8_989: "Sonarr"
        case 9_000: "Portainer"
        case 9_090: "Cockpit"
        case 9_091: "Transmission"
        case 9_696: "Prowlarr"
        case 11_434: "Ollama"
        case 18_789: "OpenClaw"
        case 27_017: "Mongo"
        case 32_400: "Plex"
        default: nil
        }
    }

    public static func impliedScheme(for port: Int) -> String? {
        switch port {
        case 80, 81, 1_234, 1_880, 2_283, 3_000, 3_001, 4_173, 4_200, 5_000, 5_055,
             5_173, 5_174, 6_767, 7_860, 7_878, 8_000, 8_006, 8_080, 8_081, 8_123, 8_188,
             8_384, 8_686, 8_888, 8_989, 9_000, 9_090, 9_091, 9_696, 11_434, 18_789, 32_400:
            "http"
        case 443, 8_443, 9_443:
            "https"
        default:
            nil
        }
    }

    public static func isNonHTTPService(_ port: Int) -> Bool {
        switch port {
        case 22, 1_883, 3_306, 3_389, 5_432, 5_900, 6_379, 8_883, 27_017: true
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
            let aKnown = $0.label != nil || isPublishedPort($0.port)
            let bKnown = $1.label != nil || isPublishedPort($1.port)
            if aKnown != bKnown { return aKnown && !bKnown }
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.address < $1.address
        }
    }

    public static func encodeJSON(_ ports: [GuestListeningPortDTO]) -> String? {
        JSONColumnCoding.encode(canonicalize(ports))
    }

    /// Persist a collect result. `collected == nil` means unavailable: clear the columns.
    /// Unchanged canonicalize keeps the previous JSON/timestamp and sets `changed` false
    /// so the poll can skip rewriting port columns.
    public static func persistFields(
        collected: [GuestListeningPortDTO]?,
        previousJSON: String?,
        previousCollectedAt: String?,
        now: String,
    ) -> (json: String?, collectedAt: String?, changed: Bool) {
        guard let collected else {
            let changed = previousJSON != nil || previousCollectedAt != nil
            return (nil, nil, changed)
        }
        let next = canonicalize(collected)
        if let previousJSON,
           let previous = JSONColumnCoding.decodeArray(GuestListeningPortDTO.self, from: previousJSON),
           canonicalize(previous) == next {
            return (previousJSON, previousCollectedAt, false)
        }
        return (encodeJSON(next), now, true)
    }

    public static func remainingCollectBudget(until deadline: Date, now: Date = Date()) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
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

    /// True when guest-osinfo or the Workload guest type names Windows.
    /// Linux collect (`ss` / `netstat` / `/proc`) must not run in that case.
    public static func looksLikeWindows(_ hint: String?) -> Bool {
        guard let hint else { return false }
        let lower = hint.lowercased()
        return lower.contains("windows") || lower.contains("mswin")
    }

    /// `netstat -ano` plus PowerShell `Get-NetTCPConnection` table/CSV/list.
    public static func parseWindowsOutput(_ text: String) -> [GuestListeningPortDTO] {
        canonicalize(parseCommandOutput(text) + parsePowerShellNetTCP(text))
    }

    public static func parsePowerShellNetTCP(_ text: String) -> [GuestListeningPortDTO] {
        let lines = text.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        if let csv = parsePowerShellCSV(lines), !csv.isEmpty {
            return canonicalize(csv)
        }
        if let listed = parsePowerShellList(lines), !listed.isEmpty {
            return canonicalize(listed)
        }

        var ports: [GuestListeningPortDTO] = []
        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("LOCALADDRESS") || upper.hasPrefix("LOCAL ADDRESS") {
                continue
            }
            if line.allSatisfy({ $0 == "-" || $0.isWhitespace }) { continue }
            guard isListenState(line) else { continue }
            if let fromEndpoint = parseListenLine(line) {
                ports.append(fromEndpoint)
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, let port = Int(fields[1]),
                  let item = makePort(address: fields[0], port: port)
            else { continue }
            ports.append(item)
        }
        return canonicalize(ports)
    }

    static func collect(
        using client: QMPClient,
        now: Date = Date(),
        osHint: String? = nil,
    ) -> [GuestListeningPortDTO]? {
        let deadline = now.addingTimeInterval(collectTimeoutSeconds)
        if looksLikeWindows(osHint) {
            return collectWindows(using: client, deadline: deadline)
        }
        return collectUnix(using: client, deadline: deadline)
    }

    private static func collectUnix(using client: QMPClient, deadline: Date) -> [GuestListeningPortDTO]? {
        let raw: [GuestListeningPortDTO]
        if let text = execCapture(
            client,
            path: "/bin/sh",
            arg: ["-c", "(ss -lntH || ss -lnt || netstat -lnt) 2>/dev/null"],
            deadline: deadline,
        ) {
            raw = parseCommandOutput(text)
        } else if let text = firstExec(
            client,
            paths: ["/usr/bin/ss", "/bin/ss", "/usr/sbin/ss"],
            arg: ["-lntH"],
            deadline: deadline,
        ) {
            raw = parseCommandOutput(text)
        } else if let text = firstExec(
            client,
            paths: ["/usr/bin/netstat", "/bin/netstat"],
            arg: ["-lnt"],
            deadline: deadline,
        ) {
            raw = parseCommandOutput(text)
        } else if remainingCollectBudget(until: deadline) > 0,
                  let tcp = readGuestFile(client, path: "/proc/net/tcp", deadline: deadline) {
            let tcp6 = remainingCollectBudget(until: deadline) > 0
                ? readGuestFile(client, path: "/proc/net/tcp6", deadline: deadline)
                : nil
            raw = parseProcNet(tcp: tcp, tcp6: tcp6)
        } else {
            return nil
        }
        return decoratePublished(raw, using: client, deadline: deadline)
    }

    /// First snapshot that parses at least one TCP listen row.
    /// Empty parses are not success: localized `netstat` can emit ABHÖREN
    /// (or similar) and must fall through to `cmd` / PowerShell.
    static func firstNonEmptyWindowsParse(_ snapshots: [() -> String?]) -> [GuestListeningPortDTO]? {
        var empty: [GuestListeningPortDTO]?
        for snapshot in snapshots {
            guard let text = snapshot() else { continue }
            let parsed = parseWindowsOutput(text)
            if !parsed.isEmpty { return parsed }
            empty = parsed
        }
        return empty
    }

    private static func collectWindows(using client: QMPClient, deadline: Date) -> [GuestListeningPortDTO]? {
        let raw = firstNonEmptyWindowsParse([
            {
                firstExec(
                    client,
                    paths: [#"C:\Windows\System32\netstat.exe"#, "netstat.exe"],
                    arg: ["-ano"],
                    deadline: deadline,
                )
            },
            {
                firstExec(
                    client,
                    paths: [#"C:\Windows\System32\cmd.exe"#, "cmd.exe"],
                    arg: ["/c", "netstat -ano"],
                    deadline: deadline,
                )
            },
            {
                firstExec(
                    client,
                    paths: [
                        #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#,
                        "powershell.exe",
                    ],
                    arg: windowsPowerShellListenArgs,
                    deadline: deadline,
                )
            },
        ])
        guard let raw else { return nil }
        return decoratePublished(raw, using: client, deadline: deadline, probeHTTP: false)
    }

    static func decoratePublished(
        _ ports: [GuestListeningPortDTO],
        using client: QMPClient,
        deadline: Date,
        probeHTTP: Bool = true,
    ) -> [GuestListeningPortDTO] {
        let visible = selectPublished(ports)
        let candidates = visible.map(\.port).filter(isHTTPProbeCandidate)
        guard probeHTTP, !candidates.isEmpty else {
            return applyHTTPSchemes(visible, probedHTTP: [], probeRan: false)
        }
        guard remainingCollectBudget(until: deadline) > 0 else {
            return applyHTTPSchemes(visible, probedHTTP: [], probeRan: false)
        }
        if let probed = probeHTTPPorts(Set(candidates).sorted(), using: client, deadline: deadline) {
            return applyHTTPSchemes(visible, probedHTTP: probed, probeRan: true)
        }
        return applyHTTPSchemes(visible, probedHTTP: [], probeRan: false)
    }

    static func probeHTTPPorts(
        _ ports: [Int],
        using client: QMPClient,
        deadline: Date,
    ) -> Set<Int>? {
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
        guard let text = execCapture(client, path: "/bin/sh", arg: ["-c", script], deadline: deadline) else {
            return nil
        }
        return Set(
            text.split(whereSeparator: \.isWhitespace)
                .compactMap { Int($0) }
                .filter { ports.contains($0) },
        )
    }

    private static func firstExec(
        _ client: QMPClient,
        paths: [String],
        arg: [String],
        deadline: Date,
    ) -> String? {
        for path in paths {
            guard remainingCollectBudget(until: deadline) > 0 else { return nil }
            if let text = execCapture(client, path: path, arg: arg, deadline: deadline) {
                return text
            }
        }
        return nil
    }

    // MARK: - Parse helpers

    private static func parsePowerShellCSV(_ lines: [String]) -> [GuestListeningPortDTO]? {
        guard let headerLine = lines.first, headerLine.contains(",") else { return nil }
        let header = splitCSV(headerLine).map { $0.lowercased() }
        guard let addrIdx = header.firstIndex(of: "localaddress"),
              let portIdx = header.firstIndex(of: "localport")
        else { return nil }
        let stateIdx = header.firstIndex(of: "state")
        var ports: [GuestListeningPortDTO] = []
        for line in lines.dropFirst() {
            let cols = splitCSV(line)
            guard addrIdx < cols.count, portIdx < cols.count, let port = Int(cols[portIdx]) else {
                continue
            }
            if let stateIdx, stateIdx < cols.count {
                let state = cols[stateIdx]
                if !state.isEmpty, !isListenState(state) { continue }
            }
            if let item = makePort(address: cols[addrIdx], port: port) {
                ports.append(item)
            }
        }
        return ports
    }

    private static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char == ",", !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(char)
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private static func parsePowerShellList(_ lines: [String]) -> [GuestListeningPortDTO]? {
        let keyed = lines.contains {
            let lower = $0.lowercased()
            return lower.hasPrefix("localaddress") && $0.contains(":")
        }
        guard keyed else { return nil }

        var address: String?
        var port: Int?
        var listen = false
        var ports: [GuestListeningPortDTO] = []

        func flush() {
            if listen, let address, let port, let item = makePort(address: address, port: port) {
                ports.append(item)
            }
            address = nil
            port = nil
            listen = false
        }

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "localaddress":
                flush()
                address = parts[1]
                listen = false
            case "localport":
                port = Int(parts[1])
            case "state":
                listen = isListenState(parts[1])
            default:
                break
            }
        }
        flush()
        return ports
    }

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
        if !isListenState(line), !hasWindowsListenForeign(fields) { return nil }

        for field in fields {
            if looksLikeRemoteWildcard(field) { continue }
            if let parsed = parseEndpoint(field) {
                return makePort(address: parsed.address, port: parsed.port)
            }
        }
        return nil
    }

    /// English LISTEN/LISTENING plus common localized netstat listen words.
    static func isListenState(_ text: String) -> Bool {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
        if folded.contains("LISTEN") { return true }
        let localized = ["ABHOREN", "ECOUTE", "ESCUCHANDO", "ESCUTANDO", "ASCOLTO", "LUISTEREN"]
        return localized.contains { folded.contains($0) }
    }

    /// Windows `netstat -ano` marks listeners with foreign `0.0.0.0:0` / `[::]:0`.
    private static func hasWindowsListenForeign(_ fields: [String]) -> Bool {
        fields.contains { token in
            let t = token.lowercased()
            return t == "0.0.0.0:0" || t == "[::]:0"
        }
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

    private static func execCapture(
        _ client: QMPClient,
        path: String,
        arg: [String],
        deadline: Date,
    ) -> String? {
        guard remainingCollectBudget(until: deadline) > 0 else { return nil }
        guard let result = try? client.executeWithArgs(
            "guest-exec",
            args: ["path": path, "arg": arg, "capture-output": true],
            maxResponseBytes: execStatusMaxResponseBytes,
        ),
            let ret = result["return"] as? [String: Any],
            let pid = jsonInt(ret["pid"])
        else { return nil }

        while remainingCollectBudget(until: deadline) > 0 {
            guard let status = try? client.executeWithArgs(
                "guest-exec-status",
                args: ["pid": pid],
                maxResponseBytes: execStatusMaxResponseBytes,
            ),
                let body = status["return"] as? [String: Any]
            else { return nil }
            if body["exited"] as? Bool != true {
                Thread.sleep(forTimeInterval: min(0.05, remainingCollectBudget(until: deadline)))
                continue
            }
            let text: String?
            if let raw = body["out-data"] as? String {
                guard let decoded = decodeBoundedOutput(raw) else { return nil }
                text = decoded
            } else {
                text = nil
            }
            let code = jsonInt(body["exitcode"]) ?? 1
            if code == 0 { return text ?? "" }
            if let text, !text.isEmpty { return text }
            return nil
        }
        return nil
    }

    private static func readGuestFile(
        _ client: QMPClient,
        path: String,
        deadline: Date,
    ) -> String? {
        guard remainingCollectBudget(until: deadline) > 0 else { return nil }
        guard let opened = try? client.executeWithArgs(
            "guest-file-open",
            args: ["path": path, "mode": "r"],
            maxResponseBytes: execStatusMaxResponseBytes,
        ),
            let handle = jsonInt(opened["return"])
        else { return nil }
        defer {
            _ = try? client.executeWithArgs("guest-file-close", args: ["handle": handle])
        }

        var chunks = Data()
        for _ in 0 ..< 16 {
            guard remainingCollectBudget(until: deadline) > 0 else { return nil }
            guard let read = try? client.executeWithArgs(
                "guest-file-read",
                args: ["handle": handle, "count": 4_096],
                maxResponseBytes: execStatusMaxResponseBytes,
            ),
                let body = read["return"] as? [String: Any]
            else { break }
            if let data = decodeBase64(body["buf-b64"] as? String) {
                chunks.append(data)
                if chunks.count > execOutputMaxBytes { return nil }
            }
            if body["eof"] as? Bool == true { break }
        }
        return String(data: chunks, encoding: .utf8)
    }

    static func decodeBoundedOutput(_ value: String?, maxBytes: Int = execOutputMaxBytes) -> String? {
        guard let data = decodeBase64(value) else { return nil }
        guard data.count <= maxBytes else { return nil }
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
// swiftlint:enable type_body_length file_length
