import Foundation

extension DyldCacheExtractor {
    struct Subcache {
        let path: URL
        let uuid: Data?
    }

    private enum SubcacheLayout {
        static let arrayOffset = 392
        static let headerSize = 400
        static let cacheSubTypeOffset = 456
        static let legacyEntrySize = 24
        static let entrySize = 56
        static let maxCount = 1_024
    }

    static func subcacheCount(cachePath: URL, confinedTo root: URL) -> Int? {
        guard let handle = try? ScannerFileReader.fileHandle(at: cachePath, confinedTo: root) else { return nil }
        defer { try? handle.close() }
        return readSubcaches(mainCachePath: cachePath, mainFileHandle: handle, confinedTo: root)?.count
    }

    static func readSubcaches(
        mainCachePath: URL,
        mainFileHandle: FileHandle,
        confinedTo root: URL
    ) -> [Subcache]? {
        guard let header = try? readData(fileHandle: mainFileHandle, at: 0, length: SubcacheLayout.headerSize),
              header.starts(with: cacheMagicPrefix.utf8),
              let mappingOffset = loadUInt32(header, at: 16) else { return nil }

        // mappingOffset marks the end of the versioned header, including which subcache entry format it uses.
        guard mappingOffset >= SubcacheLayout.headerSize else {
            return legacySubcaches(mainCachePath: mainCachePath, confinedTo: root)
        }
        guard let offset = loadUInt32(header, at: SubcacheLayout.arrayOffset),
              let count = loadUInt32(header, at: SubcacheLayout.arrayOffset + 4),
              count <= SubcacheLayout.maxCount else { return nil }
        guard count > 0 else { return [] }

        let hasSuffix = mappingOffset > SubcacheLayout.cacheSubTypeOffset
        let entrySize = hasSuffix ? SubcacheLayout.entrySize : SubcacheLayout.legacyEntrySize
        let byteCount = Int(count) * entrySize
        guard offset >= mappingOffset,
              let entries = try? readData(fileHandle: mainFileHandle, at: UInt64(offset), length: byteCount),
              entries.count == byteCount else { return nil }

        var result: [Subcache] = []
        var suffixes: Set<String> = []
        for index in 0..<Int(count) {
            guard !Task.isCancelled else { return nil }
            let entryOffset = index * entrySize
            let suffix: String
            if hasSuffix {
                let bytes = entries[(entryOffset + SubcacheLayout.legacyEntrySize)..<(entryOffset + entrySize)]
                guard let parsed = subcacheSuffix(bytes) else { return nil }
                suffix = parsed
            } else {
                suffix = ".\(index + 1)"
            }
            guard suffixes.insert(suffix).inserted else { return nil }
            result.append(Subcache(
                path: URL(fileURLWithPath: mainCachePath.path + suffix),
                uuid: entries.subdata(in: entryOffset..<(entryOffset + 16))
            ))
        }
        return result
    }

    private static func subcacheSuffix(_ bytes: Data.SubSequence) -> String? {
        guard let terminator = bytes.firstIndex(of: 0) else { return nil }
        let suffix = bytes[..<terminator]
        guard suffix.count > 1, suffix.first == 0x2E,
              suffix.allSatisfy({ byte in
                  (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                      || (0x61...0x7A).contains(byte) || [0x2D, 0x2E, 0x5F].contains(byte)
              }) else { return nil }
        return String(bytes: suffix, encoding: .ascii)
    }

    private static func legacySubcaches(mainCachePath: URL, confinedTo root: URL) -> [Subcache] {
        var result: [Subcache] = []
        for index in 1...99 {
            guard !Task.isCancelled else { return [] }
            let candidates = [".\(index)", String(format: ".%02d", index)]
            var found: URL?
            for suffix in candidates {
                let path = URL(fileURLWithPath: mainCachePath.path + suffix)
                if let handle = try? ScannerFileReader.fileHandle(at: path, confinedTo: root) {
                    try? handle.close()
                    found = path
                    break
                }
            }
            guard let found else { break }
            result.append(Subcache(path: found, uuid: nil))
        }
        return result
    }
}
