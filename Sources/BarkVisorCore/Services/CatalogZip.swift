import BarkVisorZlibInflate
import Foundation

enum CatalogZip {
    static func files(from data: Data) throws -> [String: Data] {
        guard data.count >= 22 else {
            throw BarkVisorError.repositorySyncFailed("App catalog archive is not a zip")
        }
        guard let eocd = findEOCD(data) else {
            throw BarkVisorError.repositorySyncFailed("App catalog zip is missing a directory")
        }
        let cdOffset = Int(u32(data, eocd + 16))
        let cdSize = Int(u32(data, eocd + 12))
        let cdEnd = cdOffset + cdSize
        guard cdOffset >= 0, cdEnd <= data.count else {
            throw BarkVisorError.repositorySyncFailed("App catalog zip directory is truncated")
        }
        var files: [String: Data] = [:]
        var cursor = cdOffset
        while cursor + 46 <= cdEnd {
            guard u32(data, cursor) == 0x0201_4B50 else { break }
            let method = Int(u16(data, cursor + 10))
            let compressed = Int(u32(data, cursor + 20))
            let uncompressed = Int(u32(data, cursor + 24))
            let nameLen = Int(u16(data, cursor + 28))
            let extraLen = Int(u16(data, cursor + 30))
            let commentLen = Int(u16(data, cursor + 32))
            let localOffset = Int(u32(data, cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart ..< nameEnd), encoding: .utf8) ?? ""
            let payload = try payloadBytes(
                data: data,
                localOffset: localOffset,
                method: method,
                compressed: compressed,
                uncompressed: uncompressed,
            )
            if !name.isEmpty, !name.hasSuffix("/"), let payload {
                files[name] = payload
            }
            cursor = nameEnd + extraLen + commentLen
        }
        return files
    }

    static func appFiles(from zip: Data) throws -> [String: Data] {
        let raw = try files(from: zip)
        var out: [String: Data] = [:]
        for (name, bytes) in raw {
            guard let relative = appRelativePath(name) else { continue }
            out[relative] = bytes
        }
        return out
    }

    static func appRelativePath(_ name: String) -> String? {
        let parts = name.split(separator: "/").map(String.init)
        guard !parts.contains("..") else { return nil }
        var rest = parts
        if rest.first == "__MACOSX" { return nil }
        if rest.contains("converted") { return nil }
        if let appsIndex = rest.firstIndex(of: "apps") {
            rest = Array(rest[appsIndex...])
        }
        guard rest.first == "apps", rest.count >= 3 else { return nil }
        return rest.joined(separator: "/")
    }

    private static func payloadBytes(
        data: Data,
        localOffset: Int,
        method: Int,
        compressed: Int,
        uncompressed: Int,
    ) throws -> Data? {
        guard localOffset + 30 <= data.count else { return nil }
        guard u32(data, localOffset) == 0x0403_4B50 else { return nil }
        let nameLen = Int(u16(data, localOffset + 26))
        let extraLen = Int(u16(data, localOffset + 28))
        let start = localOffset + 30 + nameLen + extraLen
        let end = start + compressed
        guard start >= 0, end <= data.count else { return nil }
        let slice = data.subdata(in: start ..< end)
        if method == 0 { return slice }
        if method == 8 { return try inflateRaw(slice, uncompressed: uncompressed) }
        return nil
    }

    private static func findEOCD(_ data: Data) -> Int? {
        let minOff = max(0, data.count - 65_557)
        var i = data.count - 22
        while i >= minOff {
            if u32(data, i) == 0x0605_4B50 { return i }
            i -= 1
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func inflateRaw(_ input: Data, uncompressed: Int) throws -> Data {
        if input.isEmpty { return Data() }
        var destCount = max(uncompressed, 4_096)
        if destCount < input.count {
            destCount = max(input.count * 16, 4_096)
        }
        while destCount <= 32_000_000 {
            var output = Data(count: destCount)
            let result: (Int32, UInt32) = output.withUnsafeMutableBytes { dest in
                input.withUnsafeBytes { src in
                    guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress,
                          let destBase = dest.bindMemory(to: UInt8.self).baseAddress
                    else { return (-1, 0) }
                    var written: UInt32 = 0
                    let status = bv_inflate_raw(
                        srcBase,
                        UInt32(input.count),
                        destBase,
                        UInt32(destCount),
                        &written,
                    )
                    return (status, written)
                }
            }
            if result.0 == 0 {
                return output.prefix(Int(result.1))
            }
            destCount *= 2
        }
        throw BarkVisorError.repositorySyncFailed("App catalog zip could not be inflated")
    }
}
