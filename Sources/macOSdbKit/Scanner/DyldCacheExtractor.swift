import Foundation
import OSLog

/// Minimal parser for Apple's dyld_shared_cache format. Supports both legacy
/// single-file (macOS 11) and split subcache (macOS 12+) formats.
public enum DyldCacheExtractor {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "DyldCacheExtractor")

    private static let cacheMagicPrefix = "dyld_v1"

    // MARK: - Cache header structures (matching dyld_cache_format.h)

    private enum HeaderOffsets {
        static let magic: Int = 0                    // char[16]
        static let mappingOffset: Int = 16           // uint32_t
        static let mappingCount: Int = 20            // uint32_t
        static let imagesOffsetOld: Int = 24         // uint32_t (imagesOffset in old format)
        static let imagesCountOld: Int = 28          // uint32_t (imagesCount in old format)
        // Extended header fields (dyld4 format, macOS 12+)
        static let imagesTextOffset: Int = 136       // uint64_t (imagesTextOffset)
        static let imagesTextCount: Int = 144        // uint64_t (imagesTextCount)
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
    public static func extractDylibData(cachePath: URL, dylibPath: String) async -> Data? {
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

        for imageIndex in 0..<imageTable.count {
            let entryOffset = imageIndex * entrySize

            // Read path offset — different field position depending on format
            let pathFileOffset: UInt32 = imagesData.withUnsafeBytes { buffer in
                let fieldOffset = imageTable.format == .legacy
                    ? LegacyImageLayout.pathFileOffsetOffset
                    : TextImageLayout.pathOffsetOffset
                return buffer.load(
                    fromByteOffset: entryOffset + fieldOffset,
                    as: UInt32.self
                )
            }

            fileHandle.seek(toFileOffset: UInt64(pathFileOffset))
            let pathData = fileHandle.readData(ofLength: 512)
            guard let imagePath = pathData.withUnsafeBytes({ buffer -> String? in
                guard let baseAddress = buffer.baseAddress else { return nil }
                return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
            }) else { continue }

            guard imagePath == dylibPath else { continue }

            // Read image address — different field position depending on format
            let imageAddress: UInt64 = imagesData.withUnsafeBytes { buffer in
                let fieldOffset = imageTable.format == .legacy
                    ? LegacyImageLayout.addressOffset
                    : TextImageLayout.loadAddressOffset
                return buffer.load(
                    fromByteOffset: entryOffset + fieldOffset,
                    as: UInt64.self
                )
            }

            guard let result = translateAddress(imageAddress, mappings: mappings) else {
                logger.warning("Could not translate address for \(dylibPath)")
                return nil
            }

            let readSize = min(Int(result.remainingSize), 2 * 1_024 * 1_024)

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

    public static func listDylibs(cachePath: URL) -> [String] {
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

        var paths: [String] = []
        for imageIndex in 0..<imageTable.count {
            let entryOffset = imageIndex * entrySize

            let pathFileOffset: UInt32 = imagesData.withUnsafeBytes { buffer in
                let fieldOffset = imageTable.format == .legacy
                    ? LegacyImageLayout.pathFileOffsetOffset
                    : TextImageLayout.pathOffsetOffset
                return buffer.load(
                    fromByteOffset: entryOffset + fieldOffset,
                    as: UInt32.self
                )
            }

            fileHandle.seek(toFileOffset: UInt64(pathFileOffset))
            let pathData = fileHandle.readData(ofLength: 512)
            if let imagePath = pathData.withUnsafeBytes({ buffer -> String? in
                guard let baseAddress = buffer.baseAddress else { return nil }
                return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
            }) {
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
        let mappingOffsetData = fileHandle.readData(ofLength: 4)
        let mappingCountData = fileHandle.readData(ofLength: 4)
        let mappingOffset = mappingOffsetData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let mappingCount = mappingCountData.withUnsafeBytes { $0.load(as: UInt32.self) }

        guard mappingCount > 0, mappingCount < 100 else { return [] }

        fileHandle.seek(toFileOffset: UInt64(mappingOffset))
        let data = fileHandle.readData(ofLength: Int(mappingCount) * MappingLayout.size)

        var mappings: [CacheMapping] = []
        for mappingIndex in 0..<Int(mappingCount) {
            let entryOffset = mappingIndex * MappingLayout.size
            let address: UInt64 = data.withUnsafeBytes { buffer in
                buffer.load(fromByteOffset: entryOffset + MappingLayout.addressOffset, as: UInt64.self)
            }
            let size: UInt64 = data.withUnsafeBytes { buffer in
                buffer.load(fromByteOffset: entryOffset + MappingLayout.sizeOffset, as: UInt64.self)
            }
            let fileOff: UInt64 = data.withUnsafeBytes { buffer in
                buffer.load(fromByteOffset: entryOffset + MappingLayout.fileOffsetOffset, as: UInt64.self)
            }
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
    private static func readImageTableInfo(
        fileHandle: FileHandle
    ) -> ImageTableInfo {
        // Try legacy format (offset at byte 24): dyld_cache_image_info
        fileHandle.seek(toFileOffset: UInt64(HeaderOffsets.imagesOffsetOld))
        let oldOffsetData = fileHandle.readData(ofLength: 4)
        let oldCountData = fileHandle.readData(ofLength: 4)
        let oldOffset = oldOffsetData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let oldCount = oldCountData.withUnsafeBytes { $0.load(as: UInt32.self) }

        // Sanity check: if the legacy format values look reasonable, use them.
        // The offset limit is generous to handle large split caches (macOS 12+).
        if oldCount > 0, oldCount < 100_000, oldOffset > 0, oldOffset < 500_000_000 {
            return ImageTableInfo(offset: Int(oldOffset), count: Int(oldCount), format: .legacy)
        }

        // Fall back to dyld4 text image info (offset at byte 136): dyld_cache_image_text_info
        fileHandle.seek(toFileOffset: UInt64(HeaderOffsets.imagesTextOffset))
        let newOffsetData = fileHandle.readData(ofLength: 8)
        let newCountData = fileHandle.readData(ofLength: 8)
        let newOffset = newOffsetData.withUnsafeBytes { $0.load(as: UInt64.self) }
        let newCount = newCountData.withUnsafeBytes { $0.load(as: UInt64.self) }

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
            if address >= mapping.address, address < mapping.address + mapping.size {
                let offsetInMapping = address - mapping.address
                let fileOffset = mapping.fileOffset + offsetInMapping
                let remainingSize = mapping.size - offsetInMapping
                return TranslatedAddress(
                    fileOffset: fileOffset,
                    remainingSize: remainingSize,
                    sourceFile: mapping.sourceFile
                )
            }
        }
        return nil
    }
}
