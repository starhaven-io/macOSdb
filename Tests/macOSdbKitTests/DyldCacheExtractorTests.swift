import Foundation
import Testing

@testable import macOSdbKit

/// These exercise the dyld-cache parser against hostile/truncated input. The
/// parser reads attacker-controlled offsets/counts and must never trap or
/// over-read — it should return nil/[] on any malformed cache.
@Suite("DyldCacheExtractor tests")
struct DyldCacheExtractorTests {

    // MARK: - Safety: malformed input must not crash

    @Test("Empty file returns nil/empty without trapping")
    func emptyFile() async throws {
        let url = try writeCache(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DyldCacheExtractor.listDylibs(cachePath: url).isEmpty)
        #expect(await DyldCacheExtractor.extractDylibData(cachePath: url, dylibPath: "/usr/lib/x.dylib") == nil)
    }

    @Test("Non-dyld magic returns nil/empty")
    func wrongMagic() async throws {
        let url = try writeCache(Data("this is definitely not a dyld shared cache".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DyldCacheExtractor.listDylibs(cachePath: url).isEmpty)
        #expect(await DyldCacheExtractor.extractDylibData(cachePath: url, dylibPath: "/usr/lib/x.dylib") == nil)
    }

    @Test("16-byte file with valid magic but no header does not crash")
    func truncatedAfterMagic() async throws {
        // Regression: a 16-byte "dyld_v1\0…" file passes the magic check, then
        // the header reads at offset 24 land past EOF — must not trap.
        var blob = Data(count: 16)
        putMagic(&blob)
        let url = try writeCache(blob)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DyldCacheExtractor.listDylibs(cachePath: url).isEmpty)
        #expect(await DyldCacheExtractor.extractDylibData(cachePath: url, dylibPath: "/usr/lib/x.dylib") == nil)
    }

    @Test("Plausible image count with offset past EOF returns nil (truncated table)")
    func imageTableOffsetPastEOF() async throws {
        var blob = Data(count: 64)
        putMagic(&blob)
        putU32(10, at: 28, in: &blob)      // imagesCount = 10 (passes < 100_000)
        putU32(0x8000, at: 24, in: &blob)  // imagesOffset way past the 64-byte file
        let url = try writeCache(blob)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DyldCacheExtractor.listDylibs(cachePath: url).isEmpty)
        #expect(await DyldCacheExtractor.extractDylibData(cachePath: url, dylibPath: "/usr/lib/x.dylib") == nil)
    }

    @Test("Oversized image count is rejected, not honored")
    func oversizedImageCount() async throws {
        var blob = Data(count: 256)
        putMagic(&blob)
        putU32(0xFFFF_FFFF, at: 28, in: &blob)  // absurd count
        putU32(0x80, at: 24, in: &blob)
        let url = try writeCache(blob)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DyldCacheExtractor.listDylibs(cachePath: url).isEmpty)
    }

    // MARK: - Happy path: a minimal valid legacy cache still parses

    @Test("Extracts a dylib from a minimal valid legacy cache")
    func extractsFromMinimalLegacyCache() async throws {
        let dylibPath = "/usr/lib/test.dylib"
        let payload = "TESTDYLIBPAYLOAD".utf8

        var blob = Data(count: 0x400)
        putMagic(&blob)
        // Header
        putU32(0x100, at: 16, in: &blob)   // mappingOffset
        putU32(1, at: 20, in: &blob)       // mappingCount
        putU32(0x80, at: 24, in: &blob)    // imagesOffset (legacy)
        putU32(1, at: 28, in: &blob)       // imagesCount
        // Image entry at 0x80 (dyld_cache_image_info, 32 bytes)
        putU64(0x1000, at: 0x80, in: &blob)        // address
        putU32(0xC0, at: 0x80 + 24, in: &blob)     // pathFileOffset
        putString(dylibPath, at: 0xC0, in: &blob)
        // Mapping at 0x100 (dyld_cache_mapping_info, 32 bytes)
        putU64(0x1000, at: 0x100, in: &blob)       // address (covers the image vmaddr)
        putU64(0x2000, at: 0x108, in: &blob)       // size
        putU64(0x200, at: 0x110, in: &blob)        // fileOffset
        // Dylib bytes at file offset 0x200
        putBytes(Array(payload), at: 0x200, in: &blob)

        let url = try writeCache(blob)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(DyldCacheExtractor.listDylibs(cachePath: url) == [dylibPath])

        let data = await DyldCacheExtractor.extractDylibData(cachePath: url, dylibPath: dylibPath)
        let extracted = try #require(data)
        #expect(extracted.prefix(payload.count) == Data(payload))
    }

    // MARK: - Helpers

    private func writeCache(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dyld-test-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    private func putMagic(_ target: inout Data) {
        putBytes(Array("dyld_v1  arm64e".utf8), at: 0, in: &target)
    }

    private func putU32(_ value: UInt32, at offset: Int, in target: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { target.replaceSubrange(offset..<offset + 4, with: $0) }
    }

    private func putU64(_ value: UInt64, at offset: Int, in target: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { target.replaceSubrange(offset..<offset + 8, with: $0) }
    }

    private func putBytes(_ bytes: [UInt8], at offset: Int, in target: inout Data) {
        target.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }

    private func putString(_ string: String, at offset: Int, in target: inout Data) {
        putBytes(Array(string.utf8) + [0], at: offset, in: &target)
    }
}
