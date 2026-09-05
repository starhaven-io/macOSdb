import Foundation
import OSLog

/// Scans an Xcode `.xip` archive to extract toolchain component versions and SDK metadata.
package actor XcodeScanner {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "XcodeScanner")

    package var onProgress: (@Sendable (ScanProgress) -> Void)?
    package var onVerbose: (@Sendable (String) -> Void)?

    package init() {}

    package func scan(
        xipPath: URL,
        releaseName: String? = nil,
        releaseDate: String? = nil,
        xipURL: String? = nil,
        isBeta: Bool = false,
        betaNumber: Int? = nil,
        betaRevision: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil
    ) async throws -> Release {
        let startTime = Date()
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: xipPath.path) else {
            throw ScannerError.archiveNotFound(path: xipPath.path)
        }

        // Phase 1: Extract XIP archive
        sendProgress(.extractingXIP)
        Self.logger.info("Extracting Xcode XIP: \(xipPath.lastPathComponent)")
        let expandedDir = try await extractXIP(xipPath)
        try Task.checkCancellation()

        let release: Release
        do {
            release = try await scanExpandedDirectory(
                expandedDir,
                sourceFilename: xipPath.lastPathComponent,
                releaseName: releaseName,
                releaseDate: releaseDate,
                xipURL: xipURL,
                isBeta: isBeta,
                betaNumber: betaNumber,
                betaRevision: betaRevision,
                isRC: isRC,
                rcNumber: rcNumber
            )
        } catch {
            cleanup(expandedDir)
            throw error
        }

        cleanup(expandedDir)

        let elapsed = Date().timeIntervalSince(startTime)
        let elapsedStr = String(format: "%.1f", elapsed)
        Self.logger.info(
            "Xcode scan complete: \(release.displayName) — \(release.components.count) components in \(elapsedStr)s"
        )

        sendProgress(.complete)
        return release
    }

    // MARK: - XIP extraction

    /// Expanding a full Xcode `.xip` is slow (tens of GB); 90 minutes is far past
    /// a normal expansion but stops a stuck `xip` from wedging the scanner runner.
    private static let xipExpandTimeout: TimeInterval = 5_400

    private func extractXIP(_ xipPath: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-xcode-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        do {
            try ScanWorkspace.markOwned(tempDir)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }

        // Clean up the temp dir if anything after createDirectory throws
        // (including a process.run() failure).
        do {
            try Task.checkCancellation()
            sendVerbose("Extracting XIP to \(tempDir.path)")

            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xip"),
                arguments: ["--expand", xipPath.path],
                currentDirectoryURL: tempDir,
                capturesStandardOutput: false,
                capturesStandardError: true,
                timeout: Self.xipExpandTimeout
            )

            guard result.terminationStatus == 0 else {
                let errorMessage = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
                throw ScannerError.xipExtractionFailed(reason: errorMessage)
            }

            return tempDir
        } catch {
            cleanup(tempDir)
            throw error
        }
    }

    // MARK: - Xcode.app discovery

    private func findXcodeApp(in directory: URL) throws -> URL {
        let fileManager = FileManager.default

        if let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            let candidates = contents.filter {
                $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app"
            }
            guard candidates.count <= 1 else {
                throw ScannerError.xcodeAppNotFound(
                    reason: "Extracted archive contains multiple Xcode app bundles"
                )
            }
            if let app = candidates.first {
                do {
                    return try ScannerFileReader.resolvedDirectory(at: app, confinedTo: directory)
                } catch {
                    throw ScannerError.xcodeAppNotFound(reason: error.localizedDescription)
                }
            }
        }

        throw ScannerError.xcodeAppNotFound(reason: "No Xcode.app or Xcode-beta.app found in extracted archive")
    }

    // MARK: - Toolchain component extraction

    /// Resolve the binary path for a component definition, trying the fallback path if needed.
    private func resolveBinaryPath(
        for definition: ComponentDefinition,
        in baseDir: URL
    ) -> (url: URL, relativePath: String) {
        let primaryPath = baseDir.appendingPathComponent(definition.path)
        if FileManager.default.fileExists(atPath: primaryPath.path) {
            return (primaryPath, definition.path)
        }
        if let fallback = definition.fallbackPath {
            let fallbackPath = baseDir.appendingPathComponent(fallback)
            sendVerbose("\(definition.name): primary not found, trying fallback \(fallback)")
            return (fallbackPath, fallback)
        }
        return (primaryPath, definition.path)
    }

    private func extractToolchainComponents(from xcodeApp: URL) async -> [Component] {
        var components: [Component] = []
        let developerDir = xcodeApp.appendingPathComponent("Contents/Developer")
        let toolchainDir = developerDir.appendingPathComponent(
            "Toolchains/XcodeDefault.xctoolchain"
        )

        let total = toolchainComponents.count + developerComponents.count

        for (index, definition) in toolchainComponents.enumerated() {
            guard !Task.isCancelled else { break }
            sendProgress(.scanningToolchain(
                component: definition.name,
                current: index + 1,
                total: total
            ))

            let resolved = resolveBinaryPath(for: definition, in: toolchainDir)
            if let component = await extractComponent(
                from: resolved.url,
                using: definition,
                resolvedPath: resolved.relativePath,
                confinedTo: xcodeApp
            ) {
                components.append(component)
            }
        }

        for (index, definition) in developerComponents.enumerated() {
            guard !Task.isCancelled else { break }
            sendProgress(.scanningToolchain(
                component: definition.name,
                current: toolchainComponents.count + index + 1,
                total: total
            ))

            let binaryPath = developerDir.appendingPathComponent(definition.path)
            if let component = await extractComponent(
                from: binaryPath,
                using: definition,
                resolvedPath: definition.path,
                confinedTo: xcodeApp
            ) {
                components.append(component)
            }
        }

        if components.isEmpty {
            Self.logger.warning("No toolchain components extracted — check Xcode.app structure")
        } else {
            Self.logger.info("Extracted \(components.count) toolchain components")
        }
        return components
    }

    /// Extract a single component from a binary, correcting the path if a fallback was used.
    private func extractComponent(
        from binaryPath: URL,
        using definition: ComponentDefinition,
        resolvedPath: String,
        confinedTo root: URL
    ) async -> Component? {
        let data: Data
        do {
            data = try ScannerFileReader.data(at: binaryPath, confinedTo: root)
        } catch {
            sendVerbose("\(definition.name): could not read binary (\(error.localizedDescription))")
            return nil
        }

        guard var component = await ComponentExtractor.extract(from: data, using: definition) else {
            sendVerbose("\(definition.name): no version matched (\(data.count) bytes)")
            return nil
        }

        if resolvedPath != definition.path {
            component = Component(
                name: component.name,
                version: component.version,
                path: "/\(resolvedPath)",
                source: component.source
            )
        }
        return component
    }
}

extension XcodeScanner {
    private func extractMinimumOSVersion(from xcodeApp: URL) -> String? {
        let infoPlist = xcodeApp.appendingPathComponent("Contents/Info.plist")
        guard let data = try? ScannerFileReader.data(
            at: infoPlist,
            confinedTo: xcodeApp,
            maxBytes: ScannerFileReader.maxMetadataBytes
        ),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any],
              let minOS = plist["LSMinimumSystemVersion"] as? String else {
            return nil
        }
        return minOS
    }

    private func extractVersionMetadata(from xcodeApp: URL) throws -> (osVersion: String, buildNumber: String) {
        let versionPlist = xcodeApp.appendingPathComponent("Contents/version.plist")

        guard let data = try? ScannerFileReader.data(
            at: versionPlist,
            confinedTo: xcodeApp,
            maxBytes: ScannerFileReader.maxMetadataBytes
        ),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any] else {
            throw ScannerError.versionPlistNotFound(
                reason: "version.plist not found at \(versionPlist.path)"
            )
        }

        guard let version = plist["CFBundleShortVersionString"] as? String else {
            throw ScannerError.versionPlistNotFound(
                reason: "CFBundleShortVersionString not found in version.plist"
            )
        }

        let build = plist["ProductBuildVersion"] as? String ?? plist["CFBundleVersion"] as? String

        guard let build else {
            throw ScannerError.versionPlistNotFound(
                reason: "No build version found in version.plist"
            )
        }

        return (version, build)
    }

    func scanExpandedDirectory(
        _ expandedDirectory: URL,
        sourceFilename: String,
        releaseName: String? = nil,
        releaseDate: String? = nil,
        xipURL: String? = nil,
        isBeta: Bool = false,
        betaNumber: Int? = nil,
        betaRevision: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil
    ) async throws -> Release {
        let xcodeApp = try findXcodeApp(in: expandedDirectory)
        Self.logger.info("Found Xcode.app: \(xcodeApp.path)")
        try Task.checkCancellation()

        let (osVersion, buildNumber) = try extractVersionMetadata(from: xcodeApp)
        let resolvedName = releaseName ?? "Xcode \(osVersion)"
        let minOS = extractMinimumOSVersion(from: xcodeApp)
        sendVerbose("Xcode version: \(osVersion) (\(buildNumber))")
        try Task.checkCancellation()

        let (components, sdks) = try await extractComponentsAndSDKs(from: xcodeApp)

        sendProgress(.assemblingResults)
        let resolvedBeta = isRC ? false : isBeta
        return Release(
            productType: .xcode,
            osVersion: osVersion,
            buildNumber: buildNumber,
            releaseName: resolvedName,
            releaseDate: releaseDate,
            xipFile: Self.xipFilename(fromURLString: xipURL) ?? sourceFilename,
            xipURL: xipURL,
            isBeta: resolvedBeta,
            betaNumber: resolvedBeta ? betaNumber : nil,
            betaRevision: resolvedBeta ? betaRevision : nil,
            isRC: isRC,
            rcNumber: rcNumber,
            components: components,
            sdks: sdks.isEmpty ? nil : sdks,
            minimumOSVersion: minOS
        )
    }

    private func extractComponentsAndSDKs(from xcodeApp: URL) async throws -> (components: [Component], sdks: [SDKInfo]) {
        var components = await extractToolchainComponents(from: xcodeApp)
        try Task.checkCancellation()
        components.append(contentsOf: await extractFrameworkComponents(from: xcodeApp))
        try Task.checkCancellation()

        sendProgress(.parsingSDKMetadata)
        let sdks = parseSDKMetadata(from: xcodeApp)
        components.append(contentsOf: extractSDKComponents(from: xcodeApp))
        components.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        try Task.checkCancellation()
        return (components, sdks)
    }

    // MARK: - Cleanup

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Progress

    private func sendProgress(_ progress: ScanProgress) {
        onProgress?(progress)
    }

    func sendVerbose(_ message: String) {
        onVerbose?(message)
    }

    /// Apple's services-account portal wraps the real download in a `path=` query parameter
    /// (`/services-account/download?path=/.../Xcode.xip`); prefer that value over `lastPathComponent`,
    /// which would otherwise be `download`.
    static func xipFilename(fromURLString urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString) else { return nil }

        if let pathQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "path" })?
            .value,
            !pathQuery.isEmpty {
            return (pathQuery as NSString).lastPathComponent
        }

        let last = url.lastPathComponent
        return last.isEmpty ? nil : last
    }
}
