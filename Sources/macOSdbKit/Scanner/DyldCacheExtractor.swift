import Foundation
import OSLog

/// Minimal parser for Apple's dyld_shared_cache format. Supports both legacy
/// single-file (macOS 11) and split subcache (macOS 12+) formats.
enum DyldCacheExtractor {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "DyldCacheExtractor")

    private static let cacheMagicPrefix = "dyld_v1"

    // MARK: - Cache header structures (matching dyld_cache_format.h)

    private enum HeaderOffsets {
        static let mappingOffset: Int = 16           // uint32_t
        static let imagesOffsetOld: Int = 24         // uint32_t (imagesOffset in old format)
        // Extended header field (dyld4 format, macOS 12+)
        static let imagesTextOffset: Int = 136       // uint64_t (imagesTextOffset)
    }

    private enum ImageTableFormat: CustomStringConvertible {
        case legacy // dyld_cache_image_info (macOS 11+)
        case text   // dyld_cache_image_text_info (dyld4, macOS 12+)

        var description: String {
            switch self {
            case .legacy: "legacy"
            case .text: "text"
            }
        }
    }

    private enum LegacyImageLayout { // dyld_cache_image_info, 32 bytes
        static let size: Int = 32
        static let addressOffset: Int = 0            // uint64_t
        static let pathFileOffsetOffset: Int = 24    // uint32_t
    }

    private enum TextImageLayout { // dyld_cache_image_text_info, 32 bytes
        static let size: Int = 32
        static let loadAddressOffset: Int = 16       // uint64_t (after 16-byte UUID)
        static let pathOffsetOffset: Int = 28        // uint32_t (after uint32_t textSegmentSize)
    }

    private enum MappingLayout { // dyld_cache_mapping_info, 32 bytes
        static let size: Int = 32
        static let addressOffset: Int = 0            // uint64_t
        static let sizeOffset: Int = 8               // uint64_t
        static let fileOffsetOffset: Int = 16        // uint64_t
    }

    private struct CacheMapping {
        let address: UInt64
        let size: UInt64
        let fileOffset: UInt64
        let sourceFile: URL
    }

    @concurrent
    static func extractDylibData(cachePath: URL, dylibPath: String) async -> Data? {
        guard let fileHandle = try? FileHandle(forReadingFrom: cachePath) else {
            logger.warning("Could not open dyld cache: \(cachePath.path)")
            return nil
        }
        defer { try? fileHandle.close() }

        let magicData = fileHandle.readData(ofLength: 16)
        guard let magic = String(data: magicData, encoding: .utf8),
              magic.hasPrefix(cacheMagicPrefix) else {
            logger.warning("Not a valid dyld shared cache: \(cachePath.lastPathComponent)")
            return nil
        }

        let imageTable = readImageTableInfo(fileHandle: fileHandle)

        guard !imageTable.isEmpty, imageTable.count < 100_000 else {
            logger.warning("Invalid images count: \(imageTable.count)")
            return nil
        }

        let allMappings = readAllMappings(mainCachePath: cachePath, mainFileHandle: fileHandle)

        if allMappings.isEmpty {
            logger.warning("No mappings found in dyld cache")
            return nil
        }

        return findAndExtractDylib(
            dylibPath: dylibPath,
            fileHandle: fileHandle,
            imageTable: imageTable,
            mappings: allMappings
        )
    }

    private static func findAndExtractDylib(
        dylibPath: String,
        fileHandle: FileHandle,
        imageTable: ImageTableInfo,
        mappings: [CacheMapping]
    ) -> Data? {
        let entrySize = imageTable.format == .legacy
            ? LegacyImageLayout.size
            : TextImageLayout.size

        logger.debug(
            "Searching for \(dylibPath) in \(imageTable.count) images (format: \(imageTable.format))"
        )

        fileHandle.seek(toFileOffset: UInt64(imageTable.offset))
        let imagesData = fileHandle.readData(ofLength: imageTable.count * entrySize)
        guard imagesData.count == imageTable.count * entrySize else {
            logger.warning("dyld image table truncated: wanted \(imageTable.count * entrySize) bytes, got \(imagesData.count)")
            return nil
        }

        let pathFieldOffset = imageTable.format == .legacy
            ? LegacyImageLayout.pathFileOffsetOffset
            : TextImageLayout.pathOffsetOffset
        let addressFieldOffset = imageTable.format == .legacy
            ? LegacyImageLayout.addressOffset
            : TextImageLayout.loadAddressOffset

        for imageIndex in 0..<imageTable.count {
            let entryOffset = imageIndex * entrySize

            // Read path offset — different field position depending on format
            guard let pathFileOffset = loadUInt32(imagesData, at: entryOffset + pathFieldOffset) else { continue }

            guard let imagePath = readCString(fileHandle: fileHandle, at: UInt64(pathFileOffset)) else { continue }

            guard imagePath == dylibPath else { continue }

            // Read image address — different field position depending on format
            guard let imageAddress = loadUInt64(imagesData, at: entryOffset + addressFieldOffset) else { return nil }

            guard let result = translateAddress(imageAddress, mappings: mappings) else {
                logger.warning("Could not translate address for \(dylibPath)")
                return nil
            }

            // Clamp in the UInt64 domain before narrowing: a crafted mapping size
            // greater than Int.max would trap the Int(...) conversion if it ran first.
            let readSize = Int(min(result.remainingSize, 2 * 1_024 * 1_024))

            // Read from the correct cache file (may be a subcache)
            guard let sourceHandle = try? FileHandle(forReadingFrom: result.sourceFile) else {
                logger.warning("Could not open subcache: \(result.sourceFile.lastPathComponent)")
                return nil
            }
            defer { try? sourceHandle.close() }

            sourceHandle.seek(toFileOffset: UInt64(result.fileOffset))
            let dylibData = sourceHandle.readData(ofLength: readSize)
            logger.info(
                "Extracted \(dylibPath): \(dylibData.count) bytes from \(result.sourceFile.lastPathComponent)"
            )
            return dylibData
        }

        logger.debug("\(dylibPath) not found in dyld cache")
        return nil
    }

    static func listDylibs(cachePath: URL) -> [String] {
        guard let fileHandle = try? FileHandle(forReadingFrom: cachePath) else { return [] }
        defer { try? fileHandle.close() }

        let magicData = fileHandle.readData(ofLength: 16)
        guard let magic = String(data: magicData, encoding: .utf8),
              magic.hasPrefix(cacheMagicPrefix) else { return [] }

        let imageTable = readImageTableInfo(fileHandle: fileHandle)
        guard !imageTable.isEmpty, imageTable.count < 100_000 else { return [] }

        let entrySize = imageTable.format == .legacy
            ? LegacyImageLayout.size
            : TextImageLayout.size

        fileHandle.seek(toFileOffset: UInt64(imageTable.offset))
        let imagesData = fileHandle.readData(ofLength: imageTable.count * entrySize)
        guard imagesData.count == imageTable.count * entrySize else { return [] }

        let pathFieldOffset = imageTable.format == .legacy
            ? LegacyImageLayout.pathFileOffsetOffset
            : TextImageLayout.pathOffsetOffset

        var paths: [String] = []
        for imageIndex in 0..<imageTable.count {
            let entryOffset = imageIndex * entrySize

            guard let pathFileOffset = loadUInt32(imagesData, at: entryOffset + pathFieldOffset) else { continue }

            if let imagePath = readCString(fileHandle: fileHandle, at: UInt64(pathFileOffset)) {
                paths.append(imagePath)
            }
        }
        return paths
    }

    // MARK: - Mapping collection

    private static func readAllMappings(
        mainCachePath: URL,
        mainFileHandle: FileHandle
    ) -> [CacheMapping] {
        var allMappings = readMappingsFromFile(
            fileHandle: mainFileHandle,
            sourceFile: mainCachePath
        )

        let subcacheFiles = findSubcacheFiles(mainCachePath: mainCachePath)
        if !subcacheFiles.isEmpty {
            logger.info("Found \(subcacheFiles.count) subcache files")
        }

        for subcachePath in subcacheFiles {
            guard let subcacheHandle = try? FileHandle(forReadingFrom: subcachePath) else {
                logger.debug("Could not open subcache: \(subcachePath.lastPathComponent)")
                continue
            }
            defer { try? subcacheHandle.close() }

            // Verify it's a valid cache file
            let magicData = subcacheHandle.readData(ofLength: 16)
            guard let magic = String(data: magicData, encoding: .utf8),
                  magic.hasPrefix(cacheMagicPrefix) else {
                // Some subcache files may not have the standard header — try reading
                // them as raw data extensions (they share the main file's address space)
                logger.debug("Subcache \(subcachePath.lastPathComponent) has non-standard header")
                continue
            }

            let subcacheMappings = readMappingsFromFile(
                fileHandle: subcacheHandle,
                sourceFile: subcachePath
            )
            allMappings.append(contentsOf: subcacheMappings)
        }

        logger.debug("Total mappings: \(allMappings.count) across \(1 + subcacheFiles.count) files")
        return allMappings
    }

    /// Checks both `.1` (macOS 12) and `.01` (macOS 13+) naming conventions.
    private static func findSubcacheFiles(mainCachePath: URL) -> [URL] {
        let basePath = mainCachePath.path
        var subcaches: [URL] = []

        for idx in 1...99 {
            // Try non-padded first (.1, .2) — used by macOS 12 Monterey
            let unpadded = URL(fileURLWithPath: basePath + ".\(idx)")
            // Then zero-padded (.01, .02) — used by macOS 13+
            let padded = URL(fileURLWithPath: basePath + String(format: ".%02d", idx))

            if FileManager.default.fileExists(atPath: unpadded.path) {
                subcaches.append(unpadded)
            } else if FileManager.default.fileExists(atPath: padded.path) {
                subcaches.append(padded)
            } else {
                break // Subcaches are sequential; stop at first gap
            }
        }

        return subcaches
    }

    private static func readMappingsFromFile(
        fileHandle: FileHandle,
        sourceFile: URL
    ) -> [CacheMapping] {
        fileHandle.seek(toFileOffset: UInt64(HeaderOffsets.mappingOffset))
        let header = fileHandle.readData(ofLength: 8)
        guard let mappingOffset = loadUInt32(header, at: 0),
              let mappingCount = loadUInt32(header, at: 4),
              mappingCount > 0, mappingCount < 100 else { return [] }

        fileHandle.seek(toFileOffset: UInt64(mappingOffset))
        let expectedBytes = Int(mappingCount) * MappingLayout.size
        let data = fileHandle.readData(ofLength: expectedBytes)
        guard data.count == expectedBytes else { return [] }

        var mappings: [CacheMapping] = []
        for mappingIndex in 0..<Int(mappingCount) {
            let entryOffset = mappingIndex * MappingLayout.size
            guard let address = loadUInt64(data, at: entryOffset + MappingLayout.addressOffset),
                  let size = loadUInt64(data, at: entryOffset + MappingLayout.sizeOffset),
                  let fileOff = loadUInt64(data, at: entryOffset + MappingLayout.fileOffsetOffset) else { continue }
            mappings.append(CacheMapping(
                address: address,
                size: size,
                fileOffset: fileOff,
                sourceFile: sourceFile
            ))
        }
        return mappings
    }

    // MARK: - Private helpers

    private struct ImageTableInfo {
        let offset: Int
        let count: Int
        let format: ImageTableFormat

        // swiftlint:disable:next empty_count
        var isEmpty: Bool { count == 0 }
    }

    /// Tries legacy format first, falls back to dyld4 text format.
    /// All count/offset fields are untrusted; they are range-checked *before*
    /// the `UInt64`→`Int` conversion (which would otherwise trap on values > Int.max).
    private static func readImageTableInfo(
        fileHandle: FileHandle
    ) -> ImageTableInfo {
        let empty = ImageTableInfo(offset: 0, count: 0, format: .legacy)

        // Try legacy format (offset at byte 24): dyld_cache_image_info
        fileHandle.seek(toFileOffset: UInt64(HeaderOffsets.imagesOffsetOld))
        let legacy = fileHandle.readData(ofLength: 8)
        if let oldOffset = loadUInt32(legacy, at: 0), let oldCount = loadUInt32(legacy, at: 4),
           // Sanity check; the offset limit is generous for large split caches (macOS 12+).
           oldCount > 0, oldCount < 100_000, oldOffset > 0, oldOffset < 500_000_000 {
            return ImageTableInfo(offset: Int(oldOffset), count: Int(oldCount), format: .legacy)
        }

        // Fall back to dyld4 text image info (offset at byte 136): dyld_cache_image_text_info
        fileHandle.seek(toFileOffset: UInt64(HeaderOffsets.imagesTextOffset))
        let text = fileHandle.readData(ofLength: 16)
        guard let newOffset = loadUInt64(text, at: 0), let newCount = loadUInt64(text, at: 8),
              newCount > 0, newCount < 100_000, newOffset > 0, newOffset < 4_000_000_000 else {
            return empty
        }
        return ImageTableInfo(offset: Int(newOffset), count: Int(newCount), format: .text)
    }

    private struct TranslatedAddress {
        let fileOffset: UInt64
        let remainingSize: UInt64
        let sourceFile: URL
    }

    private static func translateAddress(
        _ address: UInt64,
        mappings: [CacheMapping]
    ) -> TranslatedAddress? {
        for mapping in mappings {
            // Untrusted address/size from the cache; avoid trapping on overflow.
            let (end, overflow) = mapping.address.addingReportingOverflow(mapping.size)
            guard !overflow else { continue }
            if address >= mapping.address, address < end {
                let offsetInMapping = address - mapping.address
                let (fileOffset, fileOverflow) = mapping.fileOffset.addingReportingOverflow(offsetInMapping)
                guard !fileOverflow else { continue }
                return TranslatedAddress(
                    fileOffset: fileOffset,
                    remainingSize: mapping.size - offsetInMapping,
                    sourceFile: mapping.sourceFile
                )
            }
        }
        return nil
    }

    // MARK: - Bounds-checked reads (cache contents are untrusted)

    /// Loads a little-endian integer only if `data` actually holds the bytes
    /// (`readData` returns a short buffer at EOF, which `load` would over-read).
    private static func loadUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset &+ 4 <= data.count else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func loadUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset &+ 8 <= data.count else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    }

    /// Reads a NUL-terminated path, bounded to the bytes actually read so a
    /// cache whose path offset points at non-terminated bytes can't over-read.
    private static func readCString(fileHandle: FileHandle, at offset: UInt64, maxLength: Int = 512) -> String? {
        fileHandle.seek(toFileOffset: offset)
        let data = fileHandle.readData(ofLength: maxLength)
        let bytes = data.prefix { $0 != 0 }
        guard !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}
