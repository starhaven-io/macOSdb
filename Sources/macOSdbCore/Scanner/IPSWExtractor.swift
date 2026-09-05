import Foundation
import OSLog
import ZIPFoundation

actor IPSWExtractor {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "IPSWExtractor")
    static let maxArchiveEntries = 100_000
    static let maxMetadataSize: UInt64 = 32 * 1_024 * 1_024
    static let maxKernelEntries = 2_048
    static let maxDMGEntries = 512
    static let maxKernelSize: UInt64 = 1 * 1_024 * 1_024 * 1_024
    static let maxKernelBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let maxDMGSize: UInt64 = 32 * 1_024 * 1_024 * 1_024
    static let maxDMGBytes: UInt64 = 48 * 1_024 * 1_024 * 1_024

    struct ExtractionResult: Sendable {
        let workDirectory: URL
        let kernelcaches: [URL]
        let systemDMG: URL
        /// Nil for macOS 11–12 (dyld cache is on the system DMG).
        let cryptexDMG: URL?
        let osVersion: String
        let buildNumber: String
        /// From BuildManifest.plist `Ap,ProductType` entries.
        let kernelDeviceMap: [String: [String]]
    }

    func extract(ipswPath: URL) async throws -> ExtractionResult {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: ipswPath.path) else {
            throw ScannerError.ipswNotFound(path: ipswPath.path)
        }

        Self.logger.info("Extracting IPSW: \(ipswPath.lastPathComponent)")

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        do {
            try ScanWorkspace.markOwned(workDir)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            throw error
        }

        // Clean up the work dir if anything after its creation throws; the caller
        // only cleans up once it holds the ExtractionResult.
        do {
            let archive: Archive
            do {
                archive = try Archive(url: ipswPath, accessMode: .read)
            } catch {
                throw ScannerError.ipswExtractionFailed(
                    reason: "Could not open IPSW as ZIP archive: \(error)"
                )
            }

            let classified = try classifyEntries(archive)
            try Task.checkCancellation()
            let metadata = try extractMetadata(
                from: classified, archive: archive, workDir: workDir, filename: ipswPath.lastPathComponent
            )
            try Task.checkCancellation()
            let kernelcachePaths = try extractKernels(classified.kernelcaches, archive: archive, workDir: workDir)
            try Task.checkCancellation()
            let (systemDMGPath, cryptexDMGPath) = try extractDMGs(
                classified.dmgs,
                archive: archive,
                workDir: workDir,
                dmgRoles: metadata.dmgRoles
            )

            return ExtractionResult(
                workDirectory: workDir,
                kernelcaches: kernelcachePaths.sorted { $0.lastPathComponent < $1.lastPathComponent },
                systemDMG: systemDMGPath,
                cryptexDMG: cryptexDMGPath,
                osVersion: metadata.osVersion,
                buildNumber: metadata.buildNumber,
                kernelDeviceMap: metadata.kernelDeviceMap
            )
        } catch {
            cleanup(workDirectory: workDir)
            throw error
        }
    }
}

// MARK: - Extraction helpers

extension IPSWExtractor {
    private struct ClassifiedEntries {
        var kernelcaches: [Entry] = []
        var dmgs: [Entry] = []
        var buildManifest: Entry?
        var restorePlist: Entry?
    }

    private struct IPSWMetadata {
        let osVersion: String
        let buildNumber: String
        let dmgRoles: [String: String]
        let kernelDeviceMap: [String: [String]]
    }

    private func classifyEntries(_ archive: Archive) throws -> ClassifiedEntries {
        var result = ClassifiedEntries()
        var entryCount = 0
        for entry in archive {
            try Task.checkCancellation()
            entryCount += 1
            let name = entry.path
            let basename = URL(fileURLWithPath: name).lastPathComponent
            if basename.hasPrefix("kernelcache") {
                try Self.requireRegularArchiveEntry(entry)
                result.kernelcaches.append(entry)
            } else if name.hasSuffix(".dmg") || name.hasSuffix(".dmg.aea") {
                try Self.requireRegularArchiveEntry(entry)
                result.dmgs.append(entry)
            } else if basename == "BuildManifest.plist" {
                try Self.requireRegularArchiveEntry(entry)
                result.buildManifest = entry
            } else if basename == "Restore.plist" {
                try Self.requireRegularArchiveEntry(entry)
                result.restorePlist = entry
            }
            try Self.validateEntryCounts(
                total: entryCount,
                kernels: result.kernelcaches.count,
                dmgs: result.dmgs.count
            )
        }
        return result
    }

    private static func requireRegularArchiveEntry(_ entry: Entry) throws {
        guard entry.type == .file else {
            throw ScannerError.ipswExtractionFailed(
                reason: "Selected archive entry is not a regular file: \(entry.path)"
            )
        }
    }

    static func validateEntryCounts(total: Int, kernels: Int, dmgs: Int) throws {
        guard total <= maxArchiveEntries else {
            throw ScannerError.ipswExtractionFailed(reason: "Archive contains too many entries")
        }
        guard kernels <= maxKernelEntries else {
            throw ScannerError.ipswExtractionFailed(reason: "Archive contains too many kernelcache entries")
        }
        guard dmgs <= maxDMGEntries else {
            throw ScannerError.ipswExtractionFailed(reason: "Archive contains too many disk images")
        }
    }

    private func extractMetadata(
        from entries: ClassifiedEntries,
        archive: Archive,
        workDir: URL,
        filename: String
    ) throws -> IPSWMetadata {
        var osVersion = ""
        var buildNumber = ""
        var dmgRoles: [String: String] = [:]
        var kernelDeviceMap: [String: [String]] = [:]

        if let manifestEntry = entries.buildManifest {
            try validateMetadataSize(manifestEntry)
            let manifestPath = workDir.appendingPathComponent("BuildManifest.plist")
            _ = try extractBoundedEntry(
                manifestEntry,
                from: archive,
                to: manifestPath,
                budget: ExtractionBudget(
                    individualLimit: Self.maxMetadataSize,
                    totalSoFar: 0,
                    totalLimit: Self.maxMetadataSize
                )
            )
            let parsed = try parseManifest(at: manifestPath)
            osVersion = parsed.osVersion
            buildNumber = parsed.buildNumber
            dmgRoles = parsed.dmgRoles
            kernelDeviceMap = parsed.kernelDeviceMap
            Self.logger.info("Detected: macOS \(osVersion) (\(buildNumber))")
        } else if let restoreEntry = entries.restorePlist {
            try validateMetadataSize(restoreEntry)
            let restorePath = workDir.appendingPathComponent("Restore.plist")
            _ = try extractBoundedEntry(
                restoreEntry,
                from: archive,
                to: restorePath,
                budget: ExtractionBudget(
                    individualLimit: Self.maxMetadataSize,
                    totalSoFar: 0,
                    totalLimit: Self.maxMetadataSize
                )
            )
            (osVersion, buildNumber) = try parseRestorePlist(at: restorePath)
            Self.logger.info("Detected from Restore.plist: macOS \(osVersion) (\(buildNumber))")
        }

        if osVersion.isEmpty || buildNumber.isEmpty {
            (osVersion, buildNumber) = parseFromFilename(filename)
            if osVersion.isEmpty {
                throw ScannerError.metadataExtractionFailed(
                    reason: "Could not determine OS version from IPSW metadata or filename"
                )
            }
        }

        return IPSWMetadata(
            osVersion: osVersion,
            buildNumber: buildNumber,
            dmgRoles: dmgRoles,
            kernelDeviceMap: kernelDeviceMap
        )
    }

    private func validateMetadataSize(_ entry: Entry) throws {
        guard Self.isMetadataSizeAllowed(entry.uncompressedSize) else {
            throw ScannerError.metadataExtractionFailed(
                reason: "\(entry.path) exceeds the \(Self.maxMetadataSize)-byte metadata limit"
            )
        }
    }

    static func isMetadataSizeAllowed(_ size: UInt64) -> Bool {
        size <= maxMetadataSize
    }

    private func extractKernels(_ entries: [Entry], archive: Archive, workDir: URL) throws -> [URL] {
        try Self.validateDeclaredSizes(
            entries,
            individualLimit: Self.maxKernelSize,
            totalLimit: Self.maxKernelBytes,
            kind: "kernelcache"
        )
        let kernelsDir = workDir.appendingPathComponent("kernels")
        try FileManager.default.createDirectory(at: kernelsDir, withIntermediateDirectories: true)

        var paths: [URL] = []
        var extractedBytes: UInt64 = 0
        for entry in entries {
            try Task.checkCancellation()
            let basename = URL(fileURLWithPath: entry.path).lastPathComponent
            let destPath = kernelsDir.appendingPathComponent(basename)
            extractedBytes += try extractBoundedEntry(
                entry,
                from: archive,
                to: destPath,
                budget: ExtractionBudget(
                    individualLimit: Self.maxKernelSize,
                    totalSoFar: extractedBytes,
                    totalLimit: Self.maxKernelBytes
                )
            )
            paths.append(destPath)
            Self.logger.debug("Extracted kernel: \(basename)")
        }
        return paths
    }

    private func extractDMGs(
        _ dmgEntries: [Entry],
        archive: Archive,
        workDir: URL,
        dmgRoles: [String: String]
    ) throws -> (systemDMG: URL, cryptexDMG: URL?) {
        guard !dmgEntries.isEmpty else {
            throw ScannerError.systemDMGNotFound
        }

        let entryByFilename = Dictionary(
            dmgEntries.map { ((URL(fileURLWithPath: $0.path).lastPathComponent), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Use manifest role mapping when available
        let systemEntry: Entry
        var cryptexEntry: Entry?

        if let osFilename = dmgRoles["OS"],
           let entry = entryByFilename[osFilename] {
            systemEntry = entry
            if let cryptexFilename = dmgRoles["Cryptex1,SystemOS"] {
                cryptexEntry = entryByFilename[cryptexFilename]
            }
        } else {
            // Fallback: pick the largest DMG as the system image
            systemEntry = dmgEntries.max { $0.uncompressedSize < $1.uncompressedSize }!
            Self.logger.warning("No manifest DMG mapping; using largest DMG as system image")
        }

        let systemBasename = URL(fileURLWithPath: systemEntry.path).lastPathComponent
        let selectedDMGs = [systemEntry, cryptexEntry].compactMap { $0 }
        try Self.validateDeclaredSizes(
            selectedDMGs,
            individualLimit: Self.maxDMGSize,
            totalLimit: Self.maxDMGBytes,
            kind: "disk image"
        )
        let systemPath = workDir.appendingPathComponent(systemBasename)
        Self.logger.info("Extracting system DMG: \(systemBasename) (\(systemEntry.uncompressedSize) bytes)")
        try Task.checkCancellation()
        var extractedBytes = try extractBoundedEntry(
            systemEntry,
            from: archive,
            to: systemPath,
            budget: ExtractionBudget(
                individualLimit: Self.maxDMGSize,
                totalSoFar: 0,
                totalLimit: Self.maxDMGBytes
            )
        )

        var cryptexPath: URL?
        if let cryptexEntry {
            let cryptexBasename = URL(fileURLWithPath: cryptexEntry.path).lastPathComponent
            let path = workDir.appendingPathComponent(cryptexBasename)
            Self.logger.info("Extracting cryptex DMG: \(cryptexBasename) (\(cryptexEntry.uncompressedSize) bytes)")
            try Task.checkCancellation()
            extractedBytes += try extractBoundedEntry(
                cryptexEntry,
                from: archive,
                to: path,
                budget: ExtractionBudget(
                    individualLimit: Self.maxDMGSize,
                    totalSoFar: extractedBytes,
                    totalLimit: Self.maxDMGBytes
                )
            )
            cryptexPath = path
        }

        return (systemPath, cryptexPath)
    }

    static func validateDeclaredSizes(
        _ sizes: [UInt64],
        individualLimit: UInt64,
        totalLimit: UInt64
    ) throws {
        var total: UInt64 = 0
        for size in sizes {
            guard size <= individualLimit,
                  size <= totalLimit,
                  total <= totalLimit - size else {
                throw ScannerError.ipswExtractionFailed(reason: "Archive expansion exceeds its byte budget")
            }
            total += size
        }
    }

    private static func validateDeclaredSizes(
        _ entries: [Entry],
        individualLimit: UInt64,
        totalLimit: UInt64,
        kind: String
    ) throws {
        do {
            try validateDeclaredSizes(
                entries.map(\.uncompressedSize),
                individualLimit: individualLimit,
                totalLimit: totalLimit
            )
        } catch {
            throw ScannerError.ipswExtractionFailed(
                reason: "Selected \(kind) entries exceed the extraction byte budget"
            )
        }
    }

    func readAEAHeader(ipswPath: URL, maxBytes: Int = 256 * 1_024) throws -> Data? {
        let archive = try Archive(url: ipswPath, accessMode: .read)
        let classified = try classifyEntries(archive)

        guard let aeaEntry = classified.dmgs.first(where: {
            URL(fileURLWithPath: $0.path).pathExtension == "aea"
        }) else {
            return nil
        }

        // ZIPFoundation's consumer can't signal "stop", so once we have the bytes we
        // need, throw a sentinel to abort the extract rather than streaming the whole
        // multi-GB AEA entry — a `--key-only` scan only reads ~256 KB of header.
        var collected = Data()
        do {
            _ = try archive.extract(aeaEntry, skipCRC32: true) { chunk in
                if Task.isCancelled { throw CancellationError() }
                collected.append(chunk.prefix(maxBytes - collected.count))
                if collected.count >= maxBytes { throw HeaderRead.complete }
            }
        } catch HeaderRead.complete {
            // Captured the header prefix; the rest of the entry is intentionally skipped.
        } catch is CancellationError {
            throw CancellationError()
        }
        return collected
    }

    private enum HeaderRead: Error { case complete }

    func cleanup(workDirectory: URL) {
        do {
            try FileManager.default.removeItem(at: workDirectory)
            Self.logger.debug("Cleaned up work directory: \(workDirectory.path)")
        } catch {
            Self.logger.warning("Failed to clean up \(workDirectory.path): \(error)")
        }
    }

}
