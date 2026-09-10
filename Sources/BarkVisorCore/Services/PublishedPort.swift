import Foundation

public struct PublishedPort: Codable, Equatable, Sendable {
    public var hostPort: Int
    public var containerPort: Int
    public var proto: String
    public var url: String?

    public init(hostPort: Int, containerPort: Int, proto: String, url: String? = nil) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.url = url
    }

    public var openURL: String? {
        if let url, !url.isEmpty { return url }
        guard proto == "tcp" else { return nil }
        if containerPort == 443 || hostPort == 443 {
            return "https://127.0.0.1:\(hostPort)"
        }
        if [80, 8_080, 8_000, 3_000, 8_443, 8_888, 9_090].contains(containerPort)
            || [80, 8_080, 8_000, 3_000, 8_443, 8_888, 9_090].contains(hostPort) {
            let scheme = (containerPort == 8_443 || hostPort == 8_443) ? "https" : "http"
            return "\(scheme)://127.0.0.1:\(hostPort)"
        }
        return "http://127.0.0.1:\(hostPort)"
    }
}
