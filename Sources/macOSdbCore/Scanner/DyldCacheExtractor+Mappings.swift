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
        confinedTo root: URL,
        onDiagnostic: (@Sendable (String) -> Void)? = nil
    ) -> [CacheMapping] {
        var allMappings = readMappingsFromFile(
            fileHandle: mainFileHandle,
            sourceFile: mainCachePath
        )

        guard let subcacheFiles = readSubcaches(
            mainCachePath: mainCachePath,
            mainFileHandle: mainFileHandle,
            confinedTo: root
        ) else {
            return rejectMappings("Invalid dyld subcache table", onDiagnostic: onDiagnostic)
        }
        if !subcacheFiles.isEmpty {
            logger.info("Found \(subcacheFiles.count) subcache files")
        }

        for subcache in subcacheFiles {
            guard !Task.isCancelled else { return [] }
            guard let subcacheHandle = try? ScannerFileReader.fileHandle(
                at: subcache.path,
                confinedTo: root
            ) else {
                return rejectMappings(
                    "Could not open subcache: \(subcache.path.lastPathComponent)", onDiagnostic: onDiagnostic
                )
            }
            defer { try? subcacheHandle.close() }

            let header: Data
            do {
                header = try readData(fileHandle: subcacheHandle, length: 104)
            } catch {
                return rejectMappings(
                    "Could not read subcache \(subcache.path.lastPathComponent) header: \(error.localizedDescription)",
                    onDiagnostic: onDiagnostic
                )
            }

            guard let magic = String(data: header.prefix(16), encoding: .utf8),
                  magic.hasPrefix(cacheMagicPrefix) else {
                return rejectMappings(
                    "Subcache \(subcache.path.lastPathComponent) has non-standard header", onDiagnostic: onDiagnostic
                )
            }
            if let uuid = subcache.uuid, header.count < 104 || header.subdata(in: 88..<104) != uuid {
                return rejectMappings(
                    "Subcache \(subcache.path.lastPathComponent) UUID mismatch", onDiagnostic: onDiagnostic
                )
            }

            allMappings.append(contentsOf: readMappingsFromFile(
                fileHandle: subcacheHandle,
                sourceFile: subcache.path
            ))
        }

        logger.debug("Total mappings: \(allMappings.count) across \(1 + subcacheFiles.count) files")
        return allMappings
    }

    private static func rejectMappings(
        _ reason: String,
        onDiagnostic: (@Sendable (String) -> Void)?
    ) -> [CacheMapping] {
        guard !Task.isCancelled else { return [] }
        logger.warning("\(reason)")
        onDiagnostic?(reason)
        return []
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
