import Foundation
import OSLog
import ZIPFoundation

actor IPSWExtractor {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "IPSWExtractor")

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
        guard FileManager.default.fileExists(atPath: ipswPath.path) else {
            throw ScannerError.ipswNotFound(path: ipswPath.path)
        }

        Self.logger.info("Extracting IPSW: \(ipswPath.lastPathComponent)")

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let archive: Archive
        do {
            archive = try Archive(url: ipswPath, accessMode: .read)
        } catch {
            throw ScannerError.ipswExtractionFailed(
                reason: "Could not open IPSW as ZIP archive: \(error)"
            )
        }

        let classified = classifyEntries(archive)
        let metadata = try extractMetadata(
            from: classified, archive: archive, workDir: workDir, filename: ipswPath.lastPathComponent
        )
        let kernelcachePaths = try extractKernels(classified.kernelcaches, archive: archive, workDir: workDir)
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
    }

    // MARK: - Extraction helpers

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

    private func classifyEntries(_ archive: Archive) -> ClassifiedEntries {
        var result = ClassifiedEntries()
        for entry in archive {
            let name = entry.path
            let basename = URL(fileURLWithPath: name).lastPathComponent
            if basename.hasPrefix("kernelcache") {
                result.kernelcaches.append(entry)
            } else if name.hasSuffix(".dmg") || name.hasSuffix(".dmg.aea") {
                result.dmgs.append(entry)
            } else if basename == "BuildManifest.plist" {
                result.buildManifest = entry
            } else if basename == "Restore.plist" {
                result.restorePlist = entry
            }
        }
        return result
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
            let manifestPath = workDir.appendingPathComponent("BuildManifest.plist")
            _ = try archive.extract(manifestEntry, to: manifestPath)
            let parsed = try parseManifest(at: manifestPath)
            osVersion = parsed.osVersion
            buildNumber = parsed.buildNumber
            dmgRoles = parsed.dmgRoles
            kernelDeviceMap = parsed.kernelDeviceMap
            Self.logger.info("Detected: macOS \(osVersion) (\(buildNumber))")
        } else if let restoreEntry = entries.restorePlist {
            let restorePath = workDir.appendingPathComponent("Restore.plist")
            _ = try archive.extract(restoreEntry, to: restorePath)
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

    private func extractKernels(_ entries: [Entry], archive: Archive, workDir: URL) throws -> [URL] {
        let kernelsDir = workDir.appendingPathComponent("kernels")
        try FileManager.default.createDirectory(at: kernelsDir, withIntermediateDirectories: true)

        var paths: [URL] = []
        for entry in entries {
            let basename = URL(fileURLWithPath: entry.path).lastPathComponent
            let destPath = kernelsDir.appendingPathComponent(basename)
            _ = try archive.extract(entry, to: destPath)
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
        let systemPath = workDir.appendingPathComponent(systemBasename)
        Self.logger.info("Extracting system DMG: \(systemBasename) (\(systemEntry.uncompressedSize) bytes)")
        _ = try archive.extract(systemEntry, to: systemPath)

        var cryptexPath: URL?
        if let cryptexEntry {
            let cryptexBasename = URL(fileURLWithPath: cryptexEntry.path).lastPathComponent
            let path = workDir.appendingPathComponent(cryptexBasename)
            Self.logger.info("Extracting cryptex DMG: \(cryptexBasename) (\(cryptexEntry.uncompressedSize) bytes)")
            _ = try archive.extract(cryptexEntry, to: path)
            cryptexPath = path
        }

        return (systemPath, cryptexPath)
    }

    func readAEAHeader(ipswPath: URL, maxBytes: Int = 256 * 1_024) throws -> Data? {
        let archive = try Archive(url: ipswPath, accessMode: .read)
        let classified = classifyEntries(archive)

        guard let aeaEntry = classified.dmgs.first(where: {
            URL(fileURLWithPath: $0.path).pathExtension == "aea"
        }) else {
            return nil
        }

        var collected = Data()
        _ = try archive.extract(aeaEntry, skipCRC32: true) { chunk in
            guard collected.count < maxBytes else { return }
            let remaining = maxBytes - collected.count
            collected.append(chunk.prefix(remaining))
        }
        return collected
    }

    func cleanup(workDirectory: URL) {
        do {
            try FileManager.default.removeItem(at: workDirectory)
            Self.logger.debug("Cleaned up work directory: \(workDirectory.path)")
        } catch {
            Self.logger.warning("Failed to clean up \(workDirectory.path): \(error)")
        }
    }

    // MARK: - Metadata parsing

    private struct ManifestData {
        let osVersion: String
        let buildNumber: String
        let dmgRoles: [String: String]
        let kernelDeviceMap: [String: [String]]
    }

    private func parseManifest(at path: URL) throws -> ManifestData {
        let data = try Data(contentsOf: path)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else {
            throw ScannerError.metadataExtractionFailed(reason: "Invalid BuildManifest.plist format")
        }

        var osVersion = ""
        var buildNumber = ""
        var dmgRoles: [String: String] = [:]
        var kernelDeviceMap: [String: Set<String>] = [:]

        if let identities = plist["BuildIdentities"] as? [[String: Any]] {
            if let firstIdentity = identities.first {
                if let info = firstIdentity["Info"] as? [String: Any] {
                    buildNumber = info["BuildNumber"] as? String ?? ""
                }
                if let manifest = firstIdentity["Manifest"] as? [String: Any] {
                    if let osEntry = manifest["OS"] as? [String: Any],
                       let info = osEntry["Info"] as? [String: Any] {
                        osVersion = info["ProductVersion"] as? String ?? ""
                    }

                    // Map manifest role names to DMG filenames
                    for (roleName, roleValue) in manifest {
                        if let roleDict = roleValue as? [String: Any],
                           let info = roleDict["Info"] as? [String: Any],
                           let filePath = info["Path"] as? String,
                           filePath.hasSuffix(".dmg") || filePath.hasSuffix(".dmg.aea") {
                            let filename = URL(fileURLWithPath: filePath).lastPathComponent
                            dmgRoles[roleName] = filename
                        }
                    }
                }
            }

            // Build kernel → device mapping from all build identities
            for identity in identities {
                guard let productType = identity["Ap,ProductType"] as? String,
                      let manifest = identity["Manifest"] as? [String: Any],
                      let kernelEntry = manifest["KernelCache"] as? [String: Any],
                      let kernelInfo = kernelEntry["Info"] as? [String: Any],
                      let kernelPath = kernelInfo["Path"] as? String else {
                    continue
                }
                let kernelFilename = URL(fileURLWithPath: kernelPath).lastPathComponent
                kernelDeviceMap[kernelFilename, default: []].insert(productType)
            }
        }

        if osVersion.isEmpty {
            osVersion = plist["ProductVersion"] as? String ?? ""
        }
        if buildNumber.isEmpty {
            buildNumber = plist["ProductBuildVersion"] as? String ?? ""
        }

        // Convert sets to sorted arrays for deterministic output
        let sortedMap = kernelDeviceMap.mapValues { $0.sorted() }

        return ManifestData(
            osVersion: osVersion,
            buildNumber: buildNumber,
            dmgRoles: dmgRoles,
            kernelDeviceMap: sortedMap
        )
    }

    private func parseRestorePlist(at path: URL) throws -> (osVersion: String, buildNumber: String) {
        let data = try Data(contentsOf: path)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else {
            throw ScannerError.metadataExtractionFailed(reason: "Invalid Restore.plist format")
        }

        let osVersion = plist["ProductVersion"] as? String ?? ""
        let buildNumber = plist["ProductBuildVersion"] as? String ?? ""
        return (osVersion, buildNumber)
    }

    /// Parse OS version and build from IPSW filename as a last resort.
    /// Example: "UniversalMac_15.6.1_24G90_Restore.ipsw" → ("15.6.1", "24G90")
    private func parseFromFilename(_ filename: String) -> (osVersion: String, buildNumber: String) {
        let regex = /UniversalMac_(\d+\.\d+(?:\.\d+)?)_([A-Za-z0-9]+)_Restore/
        guard let match = filename.firstMatch(of: regex) else {
            return ("", "")
        }
        return (String(match.1), String(match.2))
    }
}
