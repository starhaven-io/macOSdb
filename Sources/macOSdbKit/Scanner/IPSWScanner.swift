import Foundation
import OSLog

public enum ScanProgress: Sendable {
    case extractingIPSW
    case parsingKernels(count: Int)
    case decryptingAEA
    case mountingDMG
    case mountingCryptex
    case scanningFilesystem(component: String, current: Int, total: Int)
    case scanningDyldCache(component: String, current: Int, total: Int)
    case unmountingDMG
    case assemblingResults
    case complete
}

public actor IPSWScanner {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "IPSWScanner")

    private let ipswExtractor = IPSWExtractor()
    private let aeaDecryptor = AEADecryptor()
    private let dmgMounter = DMGMounter()

    public var onProgress: (@Sendable (ScanProgress) -> Void)?
    public var onVerbose: (@Sendable (String) -> Void)?

    public init() {}

    public func scan(
        ipswPath: URL,
        releaseName: String? = nil,
        releaseDate: String? = nil,
        isBeta: Bool? = nil,
        betaNumber: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil
    ) async throws -> Release {
        let startTime = Date()

        // Phase 1: Extract IPSW
        sendProgress(.extractingIPSW)
        Self.logger.info("Starting scan of \(ipswPath.lastPathComponent)")
        let extraction = try await ipswExtractor.extract(ipswPath: ipswPath)

        let release: Release
        do {
            // Phase 2: Parse kernelcaches
            sendProgress(.parsingKernels(count: extraction.kernelcaches.count))
            Self.logger.info("Parsing \(extraction.kernelcaches.count) kernelcache files")
            let kernels = parseKernels(extraction.kernelcaches, deviceMap: extraction.kernelDeviceMap)

            guard !kernels.isEmpty else {
                throw ScannerError.noKernelcachesFound
            }

            // Phases 3–5: Decrypt, mount, and extract components
            let components = try await decryptMountAndExtract(extraction: extraction)

            // Phase 6: Assemble the Release
            sendProgress(.assemblingResults)
            let resolvedName = releaseName ?? MacOSRelease.name(
                forMajorVersion: Int(extraction.osVersion.split(separator: ".").first ?? "") ?? 0
            )

            let resolvedBeta = isBeta ?? BuildNumber.isBeta(extraction.buildNumber)

            release = Release(
                osVersion: extraction.osVersion,
                buildNumber: extraction.buildNumber,
                releaseName: resolvedName,
                releaseDate: releaseDate,
                ipswFile: ipswPath.lastPathComponent,
                scannerVersion: scannerVersion,
                isBeta: resolvedBeta,
                betaNumber: betaNumber,
                isRC: isRC,
                rcNumber: rcNumber,
                kernels: kernels,
                components: components
            )
        } catch {
            await ipswExtractor.cleanup(workDirectory: extraction.workDirectory)
            throw error
        }

        await ipswExtractor.cleanup(workDirectory: extraction.workDirectory)

        let elapsed = Date().timeIntervalSince(startTime)
        let elapsedStr = String(format: "%.1f", elapsed)
        Self.logger.info(
            "Scan complete: \(release.displayName) — \(release.kernels.count) kernels, \(release.components.count) components in \(elapsedStr)s"
        )

        sendProgress(.complete)
        return release
    }

    // MARK: - Kernel parsing

    private func parseKernels(
        _ kernelcaches: [URL],
        deviceMap: [String: [String]]
    ) -> [KernelInfo] {
        var kernels: [KernelInfo] = []
        for path in kernelcaches {
            guard var kernel = KernelParser.parse(kernelcachePath: path) else { continue }
            if kernel.devices.isEmpty {
                // Try BuildManifest device map, then board codename map (normalizing dev → release)
                let releaseKey = kernel.file.replacingOccurrences(of: ".development.", with: ".release.")
                let devices = deviceMap[kernel.file]
                    ?? boardCodeNameDevices[kernel.file] ?? boardCodeNameDevices[releaseKey]
                if let devices {
                    kernel = KernelInfo(
                        file: kernel.file,
                        darwinVersion: kernel.darwinVersion,
                        xnuVersion: kernel.xnuVersion,
                        arch: kernel.arch,
                        chip: kernel.chip,
                        devices: devices
                    )
                }
            }
            kernels.append(kernel)
        }
        return deduplicateKernels(kernels).map(resolveDeviceChips)
    }

    private func resolveDeviceChips(_ kernel: KernelInfo) -> KernelInfo {
        let deviceChips = kernel.devices.compactMap { device -> DeviceChip? in
            guard let chip = DeviceRegistry.chip(for: device) else { return nil }
            return DeviceChip(device: device, chip: chip.displayName)
        }
        guard !deviceChips.isEmpty else { return kernel }
        let resolvedChip: String
        if kernel.chip == "Unknown" {
            let uniqueChips = Set(deviceChips.map(\.chip))
            resolvedChip = uniqueChips.count == 1 ? uniqueChips.first! : "Multiple"
        } else {
            resolvedChip = kernel.chip
        }
        return KernelInfo(
            file: kernel.file,
            darwinVersion: kernel.darwinVersion,
            xnuVersion: kernel.xnuVersion,
            arch: kernel.arch,
            chip: resolvedChip,
            devices: kernel.devices,
            deviceChips: deviceChips
        )
    }

    private func deduplicateKernels(_ kernels: [KernelInfo]) -> [KernelInfo] {
        var seen: [String: Int] = [:]
        var result: [KernelInfo] = []

        for kernel in kernels {
            if let existingIndex = seen[kernel.arch] {
                let existing = result[existingIndex]
                var mergedDevices = existing.devices
                for device in kernel.devices where !mergedDevices.contains(device) {
                    mergedDevices.append(device)
                }
                var mergedDeviceChips = existing.deviceChips ?? []
                for dc in kernel.deviceChips ?? [] where !mergedDeviceChips.contains(dc) {
                    mergedDeviceChips.append(dc)
                }
                result[existingIndex] = KernelInfo(
                    file: existing.file,
                    darwinVersion: existing.darwinVersion,
                    xnuVersion: existing.xnuVersion,
                    arch: existing.arch,
                    chip: existing.chip,
                    devices: mergedDevices,
                    deviceChips: mergedDeviceChips.isEmpty ? nil : mergedDeviceChips
                )
            } else {
                seen[kernel.arch] = result.count
                result.append(kernel)
            }
        }

        return result
    }

    // MARK: - AEA decryption, DMG mounting, and component extraction

    private func decryptMountAndExtract(
        extraction: IPSWExtractor.ExtractionResult
    ) async throws -> [Component] {
        var systemDMG = extraction.systemDMG
        var cryptexDMG = extraction.cryptexDMG
        let needsAEA = AEADecryptor.isAEA(systemDMG)
            || (cryptexDMG.map { AEADecryptor.isAEA($0) } ?? false)

        if needsAEA {
            sendProgress(.decryptingAEA)
        }
        if AEADecryptor.isAEA(systemDMG) {
            Self.logger.info("Decrypting system AEA: \(systemDMG.lastPathComponent)")
            systemDMG = try await aeaDecryptor.decrypt(aeaPath: systemDMG)
        }
        if let cryptex = cryptexDMG, AEADecryptor.isAEA(cryptex) {
            Self.logger.info("Decrypting cryptex AEA: \(cryptex.lastPathComponent)")
            cryptexDMG = try await aeaDecryptor.decrypt(aeaPath: cryptex)
        }

        sendProgress(.mountingDMG)
        Self.logger.info("Mounting system DMG: \(systemDMG.lastPathComponent)")
        let systemMount = try await dmgMounter.mount(dmgPath: systemDMG)
        var fsComponents = extractFilesystemComponents(mountPoint: systemMount)

        let dyldComponents: [Component]
        if let cryptexDMG {
            sendProgress(.mountingCryptex)
            Self.logger.info("Mounting cryptex DMG: \(cryptexDMG.lastPathComponent)")
            let cryptexMount = try await dmgMounter.mount(dmgPath: cryptexDMG)

            // Scan filesystem components from cryptex too (macOS 13+ moved some binaries there)
            let cryptexFsComponents = extractFilesystemComponents(mountPoint: cryptexMount)
            let systemNames = Set(fsComponents.map(\.name))
            for component in cryptexFsComponents {
                if systemNames.contains(component.name) {
                    // Cryptex version overrides system version
                    fsComponents.removeAll { $0.name == component.name }
                }
                fsComponents.append(component)
            }

            dyldComponents = extractDyldCacheComponents(mountPoint: cryptexMount)
            sendProgress(.unmountingDMG)
            await dmgMounter.unmount(cryptexMount)
            await dmgMounter.unmount(systemMount)
        } else {
            dyldComponents = extractDyldCacheComponents(mountPoint: systemMount)
            sendProgress(.unmountingDMG)
            await dmgMounter.unmount(systemMount)
        }

        return (fsComponents + dyldComponents).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Filesystem component extraction

    private func extractFilesystemComponents(
        mountPoint: DMGMounter.MountPoint
    ) -> [Component] {
        var components: [Component] = []
        let total = filesystemComponents.count

        for (index, definition) in filesystemComponents.enumerated() {
            sendProgress(.scanningFilesystem(
                component: definition.name,
                current: index + 1,
                total: total
            ))

            let binaryPath = URL(fileURLWithPath: mountPoint.path)
                .appendingPathComponent(definition.path)

            guard let data = try? Data(contentsOf: binaryPath) else {
                sendVerbose("\(definition.name): binary not found at \(binaryPath.path)")
                continue
            }

            if let component = ComponentExtractor.extract(from: data, using: definition) {
                components.append(component)
            } else {
                sendVerbose("\(definition.name): no version matched (\(data.count) bytes)")
            }
        }

        Self.logger.info("Extracted \(components.count)/\(total) filesystem components")
        return components
    }

    // MARK: - dyld cache component extraction

    private func extractDyldCacheComponents(
        mountPoint: DMGMounter.MountPoint
    ) -> [Component] {
        let cachePath = findDyldCache(mountPoint: mountPoint.path)

        guard let cachePath else {
            sendVerbose("dyld_shared_cache not found on mounted volume")
            return []
        }

        let (allDylibs, dylibSet) = logDyldCacheDiagnostics(cachePath: cachePath)

        var components: [Component] = []
        let total = dyldCacheComponents.count

        for (index, definition) in dyldCacheComponents.enumerated() {
            sendProgress(.scanningDyldCache(
                component: definition.name,
                current: index + 1,
                total: total
            ))

            let resolvedPath = resolveDylibPath(definition.path, in: dylibSet, allPaths: allDylibs)

            guard let resolvedPath else {
                sendVerbose("\(definition.name): dylib not found in cache")
                continue
            }

            if resolvedPath != definition.path {
                sendVerbose("\(definition.name): resolved to \(resolvedPath) (expected \(definition.path))")
            }

            let resolvedDefinition = resolvedPath == definition.path
                ? definition
                : ComponentDefinition(
                    name: definition.name,
                    path: resolvedPath,
                    source: definition.source,
                    pattern: definition.pattern,
                    normalize: definition.normalize,
                    strategy: definition.strategy
                )

            guard let dylibData = DyldCacheExtractor.extractDylibData(
                cachePath: cachePath,
                dylibPath: resolvedPath
            ) else {
                sendVerbose("\(definition.name): extraction returned nil")
                continue
            }

            sendVerbose("\(definition.name): extracted \(dylibData.count) bytes")

            if let component = ComponentExtractor.extract(from: dylibData, using: resolvedDefinition) {
                components.append(component)
            } else {
                sendVerbose("\(definition.name): no version pattern matched")
            }
        }

        sendVerbose("Extracted \(components.count)/\(total) dyld cache components")
        return components
    }

    private func logDyldCacheDiagnostics(
        cachePath: URL
    ) -> (allDylibs: [String], dylibSet: Set<String>) {
        sendVerbose("Found dyld cache: \(cachePath.lastPathComponent)")

        let basePath = cachePath.path
        var subcacheCount = 0
        for idx in 1...99 {
            let unpadded = basePath + ".\(idx)"
            let padded = basePath + String(format: ".%02d", idx)
            if FileManager.default.fileExists(atPath: unpadded)
                || FileManager.default.fileExists(atPath: padded) {
                subcacheCount += 1
            } else {
                break
            }
        }
        sendVerbose("Subcache files: \(subcacheCount)")

        let allDylibs = DyldCacheExtractor.listDylibs(cachePath: cachePath)
        let dylibSet = Set(allDylibs)
        sendVerbose("Image table contains \(allDylibs.count) dylibs")
        if !allDylibs.isEmpty {
            let targetPaths = Set(dyldCacheComponents.map(\.path))
            for path in targetPaths.sorted() {
                let found = dylibSet.contains(path)
                sendVerbose("  \(path): \(found ? "found" : "NOT FOUND") in image table")
            }
        }

        return (allDylibs, dylibSet)
    }

    // MARK: - Progress

    private func sendProgress(_ progress: ScanProgress) {
        onProgress?(progress)
    }

    private func sendVerbose(_ message: String) {
        onVerbose?(message)
    }
}

// MARK: - dyld cache helpers

private func findDyldCache(mountPoint: String) -> URL? {
    let fileManager = FileManager.default

    let candidates = [
        "System/Library/dyld/dyld_shared_cache_arm64e",
        "System/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e",
        "System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
    ]

    for candidate in candidates {
        let path = URL(fileURLWithPath: mountPoint).appendingPathComponent(candidate)
        if fileManager.fileExists(atPath: path.path) {
            return path
        }
    }

    let searchPaths = [
        URL(fileURLWithPath: mountPoint).appendingPathComponent("System/Library/dyld"),
        URL(fileURLWithPath: mountPoint).appendingPathComponent(
            "System/Cryptexes/OS/System/Library/dyld"
        )
    ]

    for searchPath in searchPaths {
        if let contents = try? fileManager.contentsOfDirectory(
            at: searchPath, includingPropertiesForKeys: nil
        ) {
            if let cache = contents.first(where: {
                $0.lastPathComponent.hasPrefix("dyld_shared_cache")
                && !$0.lastPathComponent.hasSuffix(".map")
                && !$0.lastPathComponent.hasSuffix(".symbols")
            }) {
                return cache
            }
        }
    }

    return nil
}

/// Falls back to prefix matching when the soversion differs.
private func resolveDylibPath(
    _ expectedPath: String,
    in dylibSet: Set<String>,
    allPaths: [String]
) -> String? {
    if dylibSet.contains(expectedPath) {
        return expectedPath
    }

    let url = URL(fileURLWithPath: expectedPath)
    let filename = url.lastPathComponent
    let dir = url.deletingLastPathComponent().path

    guard let dotIndex = filename.firstIndex(of: ".") else {
        return nil
    }

    let baseName = String(filename[..<dotIndex])
    let prefix = dir + "/" + baseName + "."

    return allPaths.first { $0.hasPrefix(prefix) && $0.hasSuffix(".dylib") }
}

// MARK: - Board codename device mapping

/// Fallback device mapping for kernelcache filenames that use board codenames
/// instead of device model identifiers. macOS 11–13 IPSWs use names like
/// `kernelcache.release.mac13g` rather than `kernelcache.release.MacBookAir10,1_...`.
/// These mappings are derived from BuildManifest data in later macOS versions.
private let boardCodeNameDevices: [String: [String]] = [
    // M1 (H13G) — all M1 base-tier Macs
    "kernelcache.release.mac13g": [
        "MacBookAir10,1", "MacBookPro17,1", "Macmini9,1",
        "iMac21,1", "iMac21,2"
    ],
    // M1 Pro/Max (H13J) — all M1 Pro and M1 Max Macs
    "kernelcache.release.mac13j": [
        "Mac13,1", "Mac13,2",
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4"
    ],
    // M2 (H14G) — all M2 base-tier Macs
    "kernelcache.release.mac14g": [
        "Mac14,2", "Mac14,3", "Mac14,7", "Mac14,15"
    ],
    // M2 Pro/Max (H14J) — all M2 Pro and M2 Max Macs
    "kernelcache.release.mac14j": [
        "Mac14,5", "Mac14,6", "Mac14,8", "Mac14,9",
        "Mac14,10", "Mac14,12", "Mac14,13", "Mac14,14"
    ],
    // Virtual Mac
    "kernelcache.release.vma2": ["VirtualMac2,1"]
]
