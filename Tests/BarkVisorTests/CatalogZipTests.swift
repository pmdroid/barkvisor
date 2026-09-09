import Foundation
import Testing
@testable import BarkVisorCore

struct CatalogZipTests {
    @Test func `deflated files inflate`() throws {
        let payload = Data("services:\n  whoami:\n    image: traefik/whoami\n".utf8)
        let zip = try zipFile(
            name: "apps/whoami/docker-compose.yml",
            payload: deflateStored(payload),
            uncompressed: payload.count,
            method: 8,
        )
        let files = try CatalogZip.files(from: zip)
        #expect(files["apps/whoami/docker-compose.yml"] == payload)
    }

    @Test func `deflated entry stops before exceeding the uncompressed budget`() throws {
        let expanded = Data(repeating: 0, count: 2_000)
        let zip = try zipFile(
            name: "apps/bomb/zeros.bin",
            payload: deflateStored(expanded),
            uncompressed: 50,
            method: 8,
        )
        #expect(throws: BarkVisorError.self) {
            _ = try CatalogZip.files(
                from: zip,
                maxFiles: CatalogZip.maxFiles,
                maxEntryBytes: 1_000,
                maxTotalBytes: 2_000,
            )
        }
    }

    @Test func `stored entry larger than the per-file budget is rejected`() throws {
        let zip = try zipFile(
            name: "apps/x/big.bin",
            payload: Data(count: CatalogZip.maxEntryBytes + 1),
            uncompressed: CatalogZip.maxEntryBytes + 1,
            method: 0,
        )
        #expect(throws: BarkVisorError.self) {
            _ = try CatalogZip.files(from: zip)
        }
    }

    @Test func `too many zip entries are rejected`() throws {
        #expect(throws: BarkVisorError.self) {
            _ = try CatalogZip.files(from: storedCount(CatalogZip.maxFiles + 1))
        }
    }

    @Test func `total uncompressed bytes are capped across entries`() throws {
        let one = Data(count: 600)
        let zip = try zipFiles([
            ("apps/a/a.bin", one, 0, one.count),
            ("apps/b/b.bin", one, 0, one.count),
        ])
        #expect(throws: BarkVisorError.self) {
            _ = try CatalogZip.files(
                from: zip,
                maxFiles: CatalogZip.maxFiles,
                maxEntryBytes: 1_024,
                maxTotalBytes: 1_000,
            )
        }
    }

    private func storedCount(_ count: Int) -> Data {
        var locals = Data()
        var central = Data()
        for i in 0 ..< count {
            let name = "f\(i)"
            let nameData = Data(name.utf8)
            let offset = UInt32(locals.count)
            locals.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            locals.append(contentsOf: [0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            locals.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            locals.append(contentsOf: le32(0))
            locals.append(contentsOf: le32(0))
            locals.append(contentsOf: le16(UInt16(nameData.count)))
            locals.append(contentsOf: le16(0))
            locals.append(nameData)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(contentsOf: [0x14, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            central.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            central.append(contentsOf: le32(0))
            central.append(contentsOf: le32(0))
            central.append(contentsOf: le16(UInt16(nameData.count)))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le32(0))
            central.append(contentsOf: le32(offset))
            central.append(nameData)
        }
        return finishZip(locals: locals, central: central, count: count)
    }

    private func zipFile(name: String, payload: Data, uncompressed: Int, method: UInt16) throws -> Data {
        try zipFiles([(name, payload, method, uncompressed)])
    }

    private func zipFiles(_ files: [(String, Data, UInt16, Int)]) throws -> Data {
        var locals = Data()
        var central = Data()
        for (name, payload, method, uncompressed) in files {
            guard let nameData = name.data(using: .utf8) else { continue }
            let offset = UInt32(locals.count)
            locals.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            locals.append(contentsOf: [0x14, 0x00, 0x00, 0x00])
            locals.append(contentsOf: le16(method))
            locals.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            locals.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            locals.append(contentsOf: le32(UInt32(payload.count)))
            locals.append(contentsOf: le32(UInt32(uncompressed)))
            locals.append(contentsOf: le16(UInt16(nameData.count)))
            locals.append(contentsOf: le16(0))
            locals.append(nameData)
            locals.append(payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(contentsOf: [0x14, 0x00, 0x14, 0x00, 0x00, 0x00])
            central.append(contentsOf: le16(method))
            central.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            central.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            central.append(contentsOf: le32(UInt32(payload.count)))
            central.append(contentsOf: le32(UInt32(uncompressed)))
            central.append(contentsOf: le16(UInt16(nameData.count)))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0))
            central.append(contentsOf: le32(0))
            central.append(contentsOf: le32(offset))
            central.append(nameData)
        }
        return finishZip(locals: locals, central: central, count: files.count)
    }

    private func finishZip(locals: Data, central: Data, count: Int) -> Data {
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00])
        eocd.append(contentsOf: le16(UInt16(clamping: count)))
        eocd.append(contentsOf: le16(UInt16(clamping: count)))
        eocd.append(contentsOf: le32(UInt32(central.count)))
        eocd.append(contentsOf: le32(UInt32(locals.count)))
        eocd.append(contentsOf: le16(0))
        var out = Data()
        out.append(locals)
        out.append(central)
        out.append(eocd)
        return out
    }

    private func deflateStored(_ input: Data) -> Data {
        var out = Data()
        var offset = 0
        while offset < input.count || input.isEmpty {
            let n = min(65_535, input.count - offset)
            let last = offset + n >= input.count
            out.append(last ? 1 : 0)
            out.append(contentsOf: le16(UInt16(n)))
            let nlen = UInt16(truncatingIfNeeded: ~UInt16(n))
            out.append(contentsOf: le16(nlen))
            if n > 0 {
                out.append(input.subdata(in: offset ..< (offset + n)))
            }
            offset += n
            if input.isEmpty { break }
        }
        return out
    }

    private func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }
}
