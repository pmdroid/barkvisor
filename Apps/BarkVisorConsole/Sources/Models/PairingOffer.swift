import CoreImage
import Foundation

/// POST /api/pairing/codes. Omit `advertisedHost` when the Device should pick.
struct IssuePairingRequest: Encodable, Equatable {
    var advertisedHost: String?

    enum CodingKeys: String, CodingKey {
        case advertisedHost
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let advertisedHost, !advertisedHost.isEmpty {
            try container.encode(advertisedHost, forKey: .advertisedHost)
        }
    }
}

/// Settings host picker for a pairing offer. Same allow-list as PAS-226 / `LoginURI`.
enum PairingAdvertisedHost {
    static let customSentinel = "__custom__"
    static let needCustomMessage = "Enter a DNS name or IP the new Device can reach."
    static let rejectedMessage =
        "That address is not allowed in a pairing offer. Use a LAN IP, unique local IPv6, CGNAT address, or DNS name."

    struct Picker: Equatable {
        var selectedHost: String
        var customHost: String
    }

    enum Apply: Equatable {
        case skip
        case issue(String)
        case needCustomHost
        case rejectedHost
    }

    static func hostFromDeviceURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.contains("://"), let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        if trimmed.contains("/") { return trimmed }
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let inner = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty || rest.hasPrefix(":") {
                return inner
            }
        }
        if let colon = trimmed.lastIndex(of: ":"), trimmed.firstIndex(of: ":") == colon {
            let after = trimmed[trimmed.index(after: colon)...]
            if !after.isEmpty, after.allSatisfy(\.isNumber) {
                return String(trimmed[..<colon])
            }
        }
        return trimmed
    }

    static func hostForOffer(selectedHost: String, customHost: String) -> String? {
        if selectedHost == customSentinel {
            let host = hostFromDeviceURL(customHost)
            return host.isEmpty ? nil : host
        }
        let host = hostFromDeviceURL(selectedHost)
        return host.isEmpty ? nil : host
    }

    static func pairingHost(fromPayload qrPayload: String) -> String? {
        guard let components = URLComponents(string: qrPayload.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let host = components.queryItems?.first(where: { $0.name == "host" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return host.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func issuedHost(_ offer: PairingIssue) -> String? {
        let persisted = offer.advertisedHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let persisted, !persisted.isEmpty { return persisted }
        return pairingHost(fromPayload: offer.qrPayload)
    }

    static func syncPicker(from offer: PairingIssue?) -> Picker {
        guard let offer else { return Picker(selectedHost: "", customHost: "") }
        let host = issuedHost(offer)
        if let host, offer.advertisedHosts.contains(host) {
            return Picker(selectedHost: host, customHost: "")
        }
        return Picker(selectedHost: customSentinel, customHost: host ?? "")
    }

    /// Advertise URL picker: listed host, or Other / DNS name.
    static func syncAdvertisePicker(deviceUrl: String?, listedHosts: [String]) -> Picker {
        let host = hostFromDeviceURL(deviceUrl ?? "")
        if !host.isEmpty, listedHosts.contains(host) {
            return Picker(selectedHost: host, customHost: "")
        }
        if !host.isEmpty {
            return Picker(selectedHost: customSentinel, customHost: host)
        }
        if let fallback = listedHosts.first, !fallback.isEmpty {
            return Picker(selectedHost: fallback, customHost: "")
        }
        return Picker(selectedHost: customSentinel, customHost: "")
    }

    static func applyListedHost(_ selectedHost: String, currentIssued: String?) -> Apply {
        if selectedHost == customSentinel { return .skip }
        let host = hostFromDeviceURL(selectedHost)
        if host.isEmpty { return .skip }
        if host == currentIssued { return .skip }
        guard LoginURI.isAllowedHost(host) else { return .rejectedHost }
        return .issue(host)
    }

    static func applyCustomHost(_ raw: String, currentIssued: String?) -> Apply {
        let host = hostFromDeviceURL(raw)
        if host.isEmpty { return .needCustomHost }
        if host == currentIssued { return .skip }
        guard LoginURI.isAllowedHost(host) else { return .rejectedHost }
        return .issue(host)
    }
}

enum PairingQR {
    private struct Cache {
        var payload: String
        var dimension: CGFloat
        var image: CGImage
    }

    private static let lock = NSLock()
    private static var cache: Cache?

    /// QR of the pairing URI (`qrPayload`), not the short code.
    /// Same payload and size reuse the last `CGImage` so Settings' expiry tick
    /// does not allocate a `CIContext` or run `CIQRCodeGenerator` again.
    static func image(payload: String, dimension: CGFloat = 196) -> CGImage? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.payload == text, cache.dimension == dimension {
            return cache.image
        }
        guard let image = render(text: text, dimension: dimension) else { return nil }
        cache = Cache(payload: text, dimension: dimension, image: image)
        return image
    }

    private static func render(text: String, dimension: CGFloat) -> CGImage? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = dimension / extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
