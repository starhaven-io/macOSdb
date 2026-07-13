import Foundation
import OSLog

package enum ScanProgress: Sendable {
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
    // Xcode-specific phases
    case extractingXIP
    case scanningToolchain(component: String, current: Int, total: Int)
    case parsingSDKMetadata
}

package actor IPSWScanner {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "IPSWScanner")

    private let ipswExtractor = IPSWExtractor()
    private let aeaDecryptor = AEADecryptor()
    private let dmgMounter = DMGMounter()

    package var onProgress: (@Sendable (ScanProgress) -> Void)?
    package var onVerbose: (@Sendable (String) -> Void)?

    package private(set) var aeaPrivateKeyPEM: String?

    package init() {}

    package func scan(
        ipswPath: URL,
        releaseName: String? = nil,
        releaseDate: String? = nil,
        ipswURL: String? = nil,
        isBeta: Bool? = nil,
        betaNumber: Int? = nil,
        betaRevision: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil,
        isDeviceSpecific: Bool = false,
        aeaKeyPEM: String? = nil
    ) async throws -> Release {
        let startTime = Date()
        try Task.checkCancellation()

        // Phase 1: Extract IPSW
        sendProgress(.extractingIPSW)
        Self.logger.info("Starting scan of \(ipswPath.lastPathComponent)")
        let extraction = try await ipswExtractor.extract(ipswPath: ipswPath)
        try Task.checkCancellation()

        let release: Release
        do {
            // Phase 2: Parse kernelcaches
            sendProgress(.parsingKernels(count: extraction.kernelcaches.count))
            Self.logger.info("Parsing \(extraction.kernelcaches.count) kernelcache files")
            let kernels = try await parseKernels(extraction.kernelcaches, deviceMap: extraction.kernelDeviceMap)

            guard !kernels.isEmpty else {
                throw ScannerError.noKernelcachesFound
            }
            try Task.checkCancellation()

            // Phases 3–5: Decrypt, mount, and extract components
            let components = try await decryptMountAndExtract(extraction: extraction, aeaKeyPEM: aeaKeyPEM)
            try Task.checkCancellation()

            // Phase 6: Assemble the Release
            sendProgress(.assemblingResults)
            let resolvedName = releaseName ?? MacOSRelease.name(
                forMajorVersion: Int(extraction.osVersion.split(separator: ".").first ?? "") ?? 0
            )

            let resolvedBeta = isRC ? false : (isBeta ?? BuildNumber.isBeta(extraction.buildNumber))

            release = Release(
                productType: .macOS,
                osVersion: extraction.osVersion,
                buildNumber: extraction.buildNumber,
                releaseName: resolvedName,
                releaseDate: releaseDate,
                ipswFile: ipswURL.flatMap { URL(string: $0)?.lastPathComponent } ?? ipswPath.lastPathComponent,
                ipswURL: ipswURL,

                isBeta: resolvedBeta,
                betaNumber: resolvedBeta ? betaNumber : nil,
                betaRevision: resolvedBeta ? betaRevision : nil,
                isRC: isRC,
                rcNumber: rcNumber,
                isDeviceSpecific: isDeviceSpecific,
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

    package func extractAEAKey(ipswPath: URL) async throws {
        sendProgress(.extractingIPSW)
        try Task.checkCancellation()

        guard let headerData = try await ipswExtractor.readAEAHeader(ipswPath: ipswPath) else {
            Self.logger.info("No AEA encryption in \(ipswPath.lastPathComponent)")
            sendProgress(.complete)
            return
        }
        try Task.checkCancellation()

        sendProgress(.decryptingAEA)
        aeaPrivateKeyPEM = try await aeaDecryptor.deriveKeyOnly(from: headerData)
        sendProgress(.complete)
    }

    // MARK: - Kernel parsing

    /// Upper bound on kernelcaches parsed at once. Each parse reads a whole file
    /// into memory, so an unbounded fan-out over a crafted archive's many
    /// kernelcache entries could exhaust memory; a real IPSW has only a handful.
    private static let maxConcurrentKernelParses = 4

    private func parseKernels(
        _ kernelcaches: [URL],
        deviceMap: [String: [String]]
    ) async throws -> [KernelInfo] {
        try Task.checkCancellation()
        let parsed = await mapConcurrent(
            kernelcaches, maxConcurrent: Self.maxConcurrentKernelParses
        ) { path in
            await KernelParser.parse(kernelcachePath: path)
        }
        try Task.checkCancellation()

        let kernels = parsed.map { kernel -> KernelInfo in
            guard kernel.devices.isEmpty else { return kernel }
            let releaseKey = kernel.file.replacingOccurrences(of: ".development.", with: ".release.")
            let devices = deviceMap[kernel.file]
                ?? boardCodeNameDevices[kernel.file] ?? boardCodeNameDevices[releaseKey]
            guard let devices else { return kernel }
            return KernelInfo(
                file: kernel.file,
                darwinVersion: kernel.darwinVersion,
                xnuVersion: kernel.xnuVersion,
                arch: kernel.arch,
                chip: kernel.chip,
                devices: devices
            )
        }
        return kernels.map(resolveDeviceChips).sorted { $0.file < $1.file }
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

    // MARK: - AEA decryption, DMG mounting, and component extraction

    private func decryptMountAndExtract(
        extraction: IPSWExtractor.ExtractionResult,
        aeaKeyPEM: String? = nil
    ) async throws -> [Component] {
        try Task.checkCancellation()
        var systemDMG = extraction.systemDMG
        var cryptexDMG = extraction.cryptexDMG
        let needsAEA = AEADecryptor.isAEA(systemDMG)
            || (cryptexDMG.map { AEADecryptor.isAEA($0) } ?? false)

        if needsAEA {
            sendProgress(.decryptingAEA)
        }
        if AEADecryptor.isAEA(systemDMG) {
            Self.logger.info("Decrypting system AEA: \(systemDMG.lastPathComponent)")
            let result = try await aeaDecryptor.decrypt(aeaPath: systemDMG, privateKeyPEM: aeaKeyPEM)
            systemDMG = result.dmgPath
            aeaPrivateKeyPEM = result.privateKeyPEM
            try Task.checkCancellation()
        }
        if let cryptex = cryptexDMG, AEADecryptor.isAEA(cryptex) {
            Self.logger.info("Decrypting cryptex AEA: \(cryptex.lastPathComponent)")
            let result = try await aeaDecryptor.decrypt(aeaPath: cryptex, privateKeyPEM: aeaKeyPEM)
            cryptexDMG = result.dmgPath
            if aeaPrivateKeyPEM == nil {
                aeaPrivateKeyPEM = result.privateKeyPEM
            }
            try Task.checkCancellation()
        }

        sendProgress(.mountingDMG)
        Self.logger.info("Mounting system DMG: \(systemDMG.lastPathComponent)")
        let systemMount = try await dmgMounter.mount(dmgPath: systemDMG)

        let components: [Component]
        do {
            try Task.checkCancellation()
            var fsComponents = await extractFilesystemComponents(mountPoint: systemMount)
            try Task.checkCancellation()

            // Keep the system DMG mounted only while component extraction is active.
            let dyldComponents: [Component]
            if let cryptexDMG {
                let extracted = try await extractCryptexComponents(
                    from: cryptexDMG,
                    mergingInto: fsComponents
                )
                fsComponents = extracted.filesystem
                dyldComponents = extracted.dyld
            } else {
                dyldComponents = await extractDyldCacheComponents(mountPoint: systemMount)
                try Task.checkCancellation()
                sendProgress(.unmountingDMG)
            }
            components = (fsComponents + dyldComponents).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            await dmgMounter.unmount(systemMount)
            throw error
        }

        await dmgMounter.unmount(systemMount)
        return components
    }

    // MARK: - Filesystem component extraction

    private func extractFilesystemComponents(
        mountPoint: DMGMounter.MountPoint
    ) async -> [Component] {
        var components: [Component] = []
        let total = filesystemComponents.count

        for (index, definition) in filesystemComponents.enumerated() {
            guard !Task.isCancelled else { break }
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

            if let component = await ComponentExtractor.extract(from: data, using: definition) {
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
    ) async -> [Component] {
        let cachePath = findDyldCache(mountPoint: mountPoint.path)

        guard let cachePath else {
            sendVerbose("dyld_shared_cache not found on mounted volume")
            return []
        }

        let (allDylibs, dylibSet) = logDyldCacheDiagnostics(cachePath: cachePath)
        guard !Task.isCancelled else { return [] }

        var components: [Component] = []
        let total = dyldCacheComponents.count

        for (index, definition) in dyldCacheComponents.enumerated() {
            guard !Task.isCancelled else { break }
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

            guard let dylibData = await DyldCacheExtractor.extractDylibData(
                cachePath: cachePath,
                dylibPath: resolvedPath
            ) else {
                sendVerbose("\(definition.name): extraction returned nil")
                continue
            }

            sendVerbose("\(definition.name): extracted \(dylibData.count) bytes")

            if let component = await ComponentExtractor.extract(from: dylibData, using: resolvedDefinition) {
                components.append(component)
            } else {
                sendVerbose("\(definition.name): no version pattern matched")
            }
        }

        sendVerbose("Extracted \(components.count)/\(total) dyld cache components")
        return components
    }

}

extension IPSWScanner {
    private func extractCryptexComponents(
        from cryptexDMG: URL,
        mergingInto fsComponents: [Component]
    ) async throws -> (filesystem: [Component], dyld: [Component]) {
        sendProgress(.mountingCryptex)
        Self.logger.info("Mounting cryptex DMG: \(cryptexDMG.lastPathComponent)")
        let cryptexMount = try await dmgMounter.mount(dmgPath: cryptexDMG)

        do {
            try Task.checkCancellation()
            let cryptexFsComponents = await extractFilesystemComponents(mountPoint: cryptexMount)
            let mergedFsComponents = merging(fsComponents, overriddenBy: cryptexFsComponents)
            try Task.checkCancellation()

            let dyldComponents = await extractDyldCacheComponents(mountPoint: cryptexMount)
            try Task.checkCancellation()
            sendProgress(.unmountingDMG)
            await dmgMounter.unmount(cryptexMount)
            return (mergedFsComponents, dyldComponents)
        } catch {
            await dmgMounter.unmount(cryptexMount)
            throw error
        }
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

/// Merges cryptex components over system ones, with cryptex winning on name collisions.
private func merging(_ system: [Component], overriddenBy cryptex: [Component]) -> [Component] {
    guard !cryptex.isEmpty else { return system }
    let cryptexNames = Set(cryptex.map(\.name))
    return system.filter { !cryptexNames.contains($0.name) } + cryptex
}
