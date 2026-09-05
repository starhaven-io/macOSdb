import Foundation
import OSLog

extension DyldCacheExtractor {
    struct CacheMapping {
        let address: UInt64
        let size: UInt64
        let fileOffset: UInt64
        let sourceFile: URL
    }

    private enum MappingLayout {
        static let size: Int = 32
        static let addressOffset: Int = 0
        static let sizeOffset: Int = 8
        static let fileOffsetOffset: Int = 16
    }

    static func readAllMappings(
        mainCachePath: URL,
        mainFileHandle: FileHandle,
        confinedTo root: URL
    ) -> [CacheMapping] {
        var allMappings = readMappingsFromFile(
            fileHandle: mainFileHandle,
            sourceFile: mainCachePath
        )

        let subcacheFiles = findSubcacheFiles(mainCachePath: mainCachePath, confinedTo: root)
        if !subcacheFiles.isEmpty {
            logger.info("Found \(subcacheFiles.count) subcache files")
        }

        for subcachePath in subcacheFiles {
            guard !Task.isCancelled else { break }
            guard let subcacheHandle = try? ScannerFileReader.fileHandle(
                at: subcachePath,
                confinedTo: root
            ) else {
                logger.debug("Could not open subcache: \(subcachePath.lastPathComponent)")
                continue
            }
            defer { try? subcacheHandle.close() }

            let magicData: Data
            do {
                magicData = try readData(fileHandle: subcacheHandle, length: 16)
            } catch {
                logger.warning(
                    "Could not read subcache \(subcachePath.lastPathComponent) header: \(error.localizedDescription)"
                )
                continue
            }

            guard let magic = String(data: magicData, encoding: .utf8),
                  magic.hasPrefix(cacheMagicPrefix) else {
                logger.debug("Subcache \(subcachePath.lastPathComponent) has non-standard header")
                continue
            }

            allMappings.append(contentsOf: readMappingsFromFile(
                fileHandle: subcacheHandle,
                sourceFile: subcachePath
            ))
        }

        logger.debug("Total mappings: \(allMappings.count) across \(1 + subcacheFiles.count) files")
        return allMappings
    }

    private static func findSubcacheFiles(mainCachePath: URL, confinedTo root: URL) -> [URL] {
        let basePath = mainCachePath.path
        var subcaches: [URL] = []

        for index in 1...99 {
            let unpadded = URL(fileURLWithPath: basePath + ".\(index)")
            let padded = URL(fileURLWithPath: basePath + String(format: ".%02d", index))

            if canOpenCacheFile(unpadded, confinedTo: root) {
                subcaches.append(unpadded)
            } else if canOpenCacheFile(padded, confinedTo: root) {
                subcaches.append(padded)
            } else {
                break
            }
        }

        return subcaches
    }

    private static func canOpenCacheFile(_ url: URL, confinedTo root: URL) -> Bool {
        guard let fileHandle = try? ScannerFileReader.fileHandle(at: url, confinedTo: root) else {
            return false
        }
        try? fileHandle.close()
        return true
    }

    private static func readMappingsFromFile(
        fileHandle: FileHandle,
        sourceFile: URL
    ) -> [CacheMapping] {
        guard let header = try? readData(
            fileHandle: fileHandle,
            at: 16,
            length: 8
        ), let mappingOffset = loadUInt32(header, at: 0),
           let mappingCount = loadUInt32(header, at: 4),
           mappingCount > 0, mappingCount < 100 else {
            return []
        }

        let expectedBytes = Int(mappingCount) * MappingLayout.size
        guard let data = try? readData(
            fileHandle: fileHandle,
            at: UInt64(mappingOffset),
            length: expectedBytes
        ), data.count == expectedBytes else {
            return []
        }

        var mappings: [CacheMapping] = []
        for mappingIndex in 0..<Int(mappingCount) {
            guard !Task.isCancelled else { break }
            let entryOffset = mappingIndex * MappingLayout.size
            guard let address = loadUInt64(data, at: entryOffset + MappingLayout.addressOffset),
                  let size = loadUInt64(data, at: entryOffset + MappingLayout.sizeOffset),
                  let fileOffset = loadUInt64(data, at: entryOffset + MappingLayout.fileOffsetOffset) else {
                continue
            }
            mappings.append(CacheMapping(
                address: address,
                size: size,
                fileOffset: fileOffset,
                sourceFile: sourceFile
            ))
        }
        return mappings
    }
}
