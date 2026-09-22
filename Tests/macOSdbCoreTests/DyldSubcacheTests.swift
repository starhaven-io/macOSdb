import Foundation
import Synchronization
import Testing

@testable import macOSdbCore

@Suite("Dyld subcache discovery tests")
struct DyldSubcacheTests {
    @Test("Extracts named subcaches and images after a numbering gap", arguments: [1, 2])
    func extractsDeclaredSubcaches(target: Int) async throws {
        let fixture = try SubcacheFixture(suffixes: [".01", ".02.dylddata", ".03"], target: target)
        defer { fixture.remove() }

        let data = await fixture.extract()
        #expect(data?.starts(with: fixture.payload) == true)
        #expect(DyldCacheExtractor.subcacheCount(cachePath: fixture.cache, confinedTo: fixture.root) == 3)
    }

    @Test("Declared filenames are not limited to two-digit indices")
    func extractsLargeIndex() async throws {
        let fixture = try SubcacheFixture(suffixes: [".100.dyldreadonly"])
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
    }

    @Test("Reads legacy subcache table entries without suffix fields")
    func extractsLegacyTable() async throws {
        let fixture = try SubcacheFixture(suffixes: [".1", ".2"], format: .legacyTable, target: 1)
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
        #expect(DyldCacheExtractor.subcacheCount(cachePath: fixture.cache, confinedTo: fixture.root) == 2)
    }

    @Test("Preserves numbered discovery for caches without a subcache table", arguments: [".1", ".01"])
    func extractsWithoutTable(suffix: String) async throws {
        let fixture = try SubcacheFixture(suffixes: [suffix], format: .noTable)
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
    }

    @Test("Does not guess filenames when a declared table is empty")
    func emptyTableIgnoresAdjacentFiles() async throws {
        let fixture = try SubcacheFixture(suffixes: [".1"])
        defer { fixture.remove() }
        try fixture.editMain { data in
            SubcacheFixture.put(UInt32(0), at: 392, in: &data)
            SubcacheFixture.put(UInt32(0), at: 396, in: &data)
        }
        #expect(DyldCacheExtractor.subcacheCount(cachePath: fixture.cache, confinedTo: fixture.root) == 0)
        #expect(await fixture.extract() == nil)
    }

    @Test("Rejects unbounded, overlapping, or truncated subcache tables", arguments: [
        "count", "offset", "overlap", "truncated", "header"
    ])
    func rejectsMalformedTable(kind: String) async throws {
        let fixture = try SubcacheFixture(suffixes: [".1"], targetInMain: true)
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
        try fixture.editMain { data in
            switch kind {
            case "count": SubcacheFixture.put(UInt32.max, at: 396, in: &data)
            case "offset": SubcacheFixture.put(UInt32.max, at: 392, in: &data)
            case "overlap": SubcacheFixture.put(UInt32(16), at: 392, in: &data)
            case "truncated": data = data.prefix(0x400 + 55)
            default: data = data.prefix(399)
            }
        }
        #expect(DyldCacheExtractor.subcacheCount(cachePath: fixture.cache, confinedTo: fixture.root) == nil)
        #expect(try fixture.mappings().isEmpty)
        #expect(await fixture.extract() == nil)
    }

    @Test("Rejects unsafe and unterminated declared suffixes", arguments: [
        ".1/../../outside", ".1\\outside", "", "1", "." + String(repeating: "a", count: 31), ".é"
    ])
    func rejectsInvalidSuffix(suffix: String) async throws {
        let fixture = try SubcacheFixture(suffixes: [".1"], targetInMain: true)
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
        try fixture.editMain { data in
            data.replaceSubrange(0x418..<0x438, with: Data(count: 32))
            let bytes = Data(suffix.utf8)
            data.replaceSubrange(0x418..<(0x418 + bytes.count), with: bytes)
        }
        #expect(try fixture.mappings().isEmpty)
        #expect(await fixture.extract() == nil)
    }

    @Test("Rejects duplicate declared filenames")
    func rejectsDuplicateSuffixes() async throws {
        let fixture = try SubcacheFixture(suffixes: [".1", ".2"], targetInMain: true)
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
        try fixture.editMain { data in
            data.replaceSubrange(0x450..<0x470, with: data.subdata(in: 0x418..<0x438))
        }
        #expect(try fixture.mappings().isEmpty)
        #expect(await fixture.extract() == nil)
    }

    @Test("Rejects mismatched UUIDs in both subcache table formats", arguments: [true, false])
    func rejectsUUIDMismatch(hasSuffix: Bool) async throws {
        let fixture = try SubcacheFixture(
            suffixes: [".1"], format: hasSuffix ? .suffixTable : .legacyTable, targetInMain: true
        )
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
        try fixture.editMain { $0[0x400] ^= 0xFF }
        #expect(try fixture.mappings().isEmpty)
        #expect(await fixture.extract() == nil)
    }

    @Test("A missing declared subcache invalidates the mapping set")
    func rejectsMissingSubcache() async throws {
        let fixture = try SubcacheFixture(suffixes: [".01", ".02.dylddata"])
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.cache.path + ".02.dylddata"))
        #expect(try fixture.mappings().isEmpty)
        #expect(await fixture.extract() == nil)
    }

    @Test("Rejects a declared subcache symlink outside the mounted volume")
    func rejectsEscapingSubcache() async throws {
        let fixture = try SubcacheFixture(suffixes: [".01.dylddata"], targetInMain: true)
        defer { fixture.remove() }
        #expect(await fixture.extract()?.starts(with: fixture.payload) == true)
        let path = URL(fileURLWithPath: fixture.cache.path + ".01.dylddata")
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: path, to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        #expect(try fixture.mappings().isEmpty)
        #expect(await fixture.extract() == nil)
    }

    @Test("Cancellation during discovery does not report an invalid subcache table")
    func cancellationSuppressesDiagnostics() async throws {
        let fixture = try SubcacheFixture(suffixes: [".1"], targetInMain: true)
        defer { fixture.remove() }
        let messages = Mutex<[String]>([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.mappings { message in messages.withLock { $0.append(message) } }.isEmpty
        }
        #expect(try await task.value)
        #expect(messages.withLock { $0.isEmpty })
    }

    @Test("Scanner verbose output explains rejected subcaches", arguments: ["table", "missing", "uuid"])
    func reportsRejectionReason(kind: String) async throws {
        let fixture = try SubcacheFixture(
            suffixes: [".1"], targetInMain: true, dylibPath: "/usr/lib/libcurl.4.dylib"
        )
        defer { fixture.remove() }
        let reason: String
        switch kind {
        case "table":
            try fixture.editMain { SubcacheFixture.put(UInt32.max, at: 396, in: &$0) }
            reason = "Invalid dyld subcache table"
        case "missing":
            try FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.cache.path + ".1"))
            reason = "Could not open subcache: dyld_shared_cache_arm64e.1"
        default:
            try fixture.editMain { $0[0x400] ^= 0xFF }
            reason = "Subcache dyld_shared_cache_arm64e.1 UUID mismatch"
        }
        let messages = Mutex<[String]>([])
        let scanner = IPSWScanner()
        await scanner.captureVerbose { message in messages.withLock { $0.append(message) } }
        let mount = DMGMounter.MountPoint(path: fixture.root.path, deviceNode: "/dev/test")
        #expect(await scanner.extractDyldCacheComponents(mountPoint: mount).isEmpty)
        let output = messages.withLock { $0 }
        #expect(output.contains(reason))
        #expect(output.contains(kind == "table"
            ? "Subcache entries: unavailable (invalid or unreadable metadata)"
            : "Subcache entries: 1"))
        #expect(!output.contains("Subcache entries: 0"))
    }
}

private extension IPSWScanner {
    func captureVerbose(_ callback: @escaping @Sendable (String) -> Void) {
        onVerbose = callback
    }
}

private struct SubcacheFixture {
    enum Format: Sendable {
        case noTable
        case legacyTable
        case suffixTable
    }

    let root: URL
    let cache: URL
    let payload = Data("DYLIB-PAYLOAD".utf8)
    private let dylibPath: String

    init(
        suffixes: [String], format: Format = .suffixTable, target: Int = 0,
        targetInMain: Bool = false, dylibPath: String = "/usr/lib/test.dylib"
    ) throws {
        self.dylibPath = dylibPath
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dyld-subcache-\(UUID().uuidString)")
        cache = root.appendingPathComponent("System/Library/dyld/dyld_shared_cache_arm64e")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            var main = Data(count: 0x600)
            main.replaceSubrange(0..<14, with: Data("dyld_v1  arm64e".utf8))
            let mappingOffset: UInt32 = switch format {
            case .noTable: 0x100
            case .legacyTable: 456
            case .suffixTable: 0x200
            }
            Self.put(mappingOffset, at: 16, in: &main)
            if targetInMain {
                Self.put(UInt32(1), at: 20, in: &main)
                Self.put(UInt64(0x100_0000), at: Int(mappingOffset), in: &main)
                Self.put(UInt64(payload.count), at: Int(mappingOffset) + 8, in: &main)
                Self.put(UInt64(0x380), at: Int(mappingOffset) + 16, in: &main)
                main.replaceSubrange(0x380..<(0x380 + payload.count), with: payload)
            }
            Self.put(UInt32(0x300), at: 24, in: &main)
            Self.put(UInt32(1), at: 28, in: &main)
            Self.put(UInt64(targetInMain ? 0x100_0000 : (target + 1) * 0x1000), at: 0x300, in: &main)
            Self.put(UInt32(0x340), at: 0x318, in: &main)
            main.replaceSubrange(0x340..<(0x340 + dylibPath.utf8.count), with: Data(dylibPath.utf8))
            if format != .noTable {
                Self.put(UInt32(0x400), at: 392, in: &main)
                Self.put(UInt32(suffixes.count), at: 396, in: &main)
            }
            for (index, suffix) in suffixes.enumerated() {
                try writeSubcache(suffix, index: index, format: format, main: &main)
            }
            try main.write(to: cache)
        } catch {
            remove()
            throw error
        }
    }

    func extract() async -> Data? {
        await DyldCacheExtractor.extractDylibData(cachePath: cache, dylibPath: dylibPath, confinedTo: root)
    }

    func mappings(onDiagnostic: (@Sendable (String) -> Void)? = nil) throws -> [DyldCacheExtractor.CacheMapping] {
        let handle = try ScannerFileReader.fileHandle(at: cache, confinedTo: root)
        defer { try? handle.close() }
        return DyldCacheExtractor.readAllMappings(
            mainCachePath: cache, mainFileHandle: handle, confinedTo: root, onDiagnostic: onDiagnostic
        )
    }

    func editMain(_ edit: (inout Data) -> Void) throws {
        var data = try Data(contentsOf: cache)
        edit(&data)
        try data.write(to: cache)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSubcache(_ suffix: String, index: Int, format: Format, main: inout Data) throws {
        let uuid = Data(repeating: UInt8(index + 1), count: 16)
        if format != .noTable {
            let entryOffset = 0x400 + index * (format == .suffixTable ? 56 : 24)
            main.replaceSubrange(entryOffset..<(entryOffset + 16), with: uuid)
            if format == .suffixTable {
                let start = entryOffset + 24
                main.replaceSubrange(start..<(start + suffix.utf8.count), with: Data(suffix.utf8))
            }
        }
        var subcache = Data(count: 0x400)
        subcache.replaceSubrange(0..<14, with: Data("dyld_v1  arm64e".utf8))
        subcache.replaceSubrange(88..<104, with: uuid)
        Self.put(UInt32(0x100), at: 16, in: &subcache)
        Self.put(UInt32(1), at: 20, in: &subcache)
        Self.put(UInt64((index + 1) * 0x1000), at: 0x100, in: &subcache)
        Self.put(UInt64(0x200), at: 0x108, in: &subcache)
        Self.put(UInt64(0x200), at: 0x110, in: &subcache)
        subcache.replaceSubrange(0x200..<(0x200 + payload.count), with: payload)
        try subcache.write(to: URL(fileURLWithPath: cache.path + suffix))
    }

    static func put<Value: FixedWidthInteger>(_ value: Value, at offset: Int, in data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
}
