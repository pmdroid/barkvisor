import Foundation

public struct PublishedPort: Codable, Equatable, Sendable {
    public var hostPort: Int
    public var containerPort: Int
    public var proto: String
    public var url: String?
    public var hostAddress: String?

    public init(
        hostPort: Int,
        containerPort: Int,
        proto: String,
        url: String? = nil,
        hostAddress: String? = nil,
    ) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.url = url
        self.hostAddress = hostAddress
    }

    public var openURL: String? {
        if let url, !url.isEmpty { return url }
        guard proto.lowercased() == "tcp" else { return nil }
        let host = urlHost
        if containerPort == 443 || hostPort == 443 {
            return "https://\(host):\(hostPort)"
        }
        if [80, 8_080, 8_000, 3_000, 8_443, 8_888, 9_090].contains(containerPort)
            || [80, 8_080, 8_000, 3_000, 8_443, 8_888, 9_090].contains(hostPort) {
            let scheme = (containerPort == 8_443 || hostPort == 8_443) ? "https" : "http"
            return "\(scheme)://\(host):\(hostPort)"
        }
        return "http://\(host):\(hostPort)"
    }

    private var urlHost: String {
        let raw = hostAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || ComposePorts.isWildcardHost(raw) {
            return "127.0.0.1"
        }
        if raw.contains(":") {
            return raw.hasPrefix("[") ? raw : "[\(raw)]"
        }
        return raw
    }
}
