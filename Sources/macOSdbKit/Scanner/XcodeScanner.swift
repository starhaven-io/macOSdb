import Foundation
import OSLog

/// Scans an Xcode `.xip` archive to extract toolchain component versions and SDK metadata.
public actor XcodeScanner {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "XcodeScanner")

    public var onProgress: (@Sendable (ScanProgress) -> Void)?
    public var onVerbose: (@Sendable (String) -> Void)?

    public init() {}

    public func scan(
        xipPath: URL,
        releaseName: String? = nil,
        releaseDate: String? = nil,
        sourceURL: String? = nil,
        isBeta: Bool = false,
        betaNumber: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil
    ) async throws -> Release {
        let startTime = Date()

        guard FileManager.default.fileExists(atPath: xipPath.path) else {
            throw ScannerError.archiveNotFound(path: xipPath.path)
        }

        // Phase 1: Extract XIP archive
        sendProgress(.extractingXIP)
        Self.logger.info("Extracting Xcode XIP: \(xipPath.lastPathComponent)")
        let expandedDir = try await extractXIP(xipPath)

        let release: Release
        do {
            // Phase 2: Locate Xcode.app
            let xcodeApp = try findXcodeApp(in: expandedDir)
            Self.logger.info("Found Xcode.app: \(xcodeApp.path)")

            // Phase 3: Extract version metadata
            let (osVersion, buildNumber) = try extractVersionMetadata(from: xcodeApp)
            let resolvedName = releaseName ?? "Xcode \(osVersion)"
            let minOS = extractMinimumOSVersion(from: xcodeApp)
            sendVerbose("Xcode version: \(osVersion) (\(buildNumber))")

            // Phase 4: Extract toolchain and framework components
            var components = extractToolchainComponents(from: xcodeApp)
            components.append(contentsOf: extractFrameworkComponents(from: xcodeApp))

            // Phase 5: Parse SDK metadata and extract SDK components
            sendProgress(.parsingSDKMetadata)
            let sdks = parseSDKMetadata(from: xcodeApp)
            let sdkComponents = extractSDKComponents(from: xcodeApp)
            components.append(contentsOf: sdkComponents)
            components.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            // Phase 6: Assemble the Release
            sendProgress(.assemblingResults)
            release = Release(
                productType: .xcode,
                osVersion: osVersion,
                buildNumber: buildNumber,
                releaseName: resolvedName,
                releaseDate: releaseDate,
                sourceFile: xipPath.lastPathComponent,
                sourceURL: sourceURL,
                isBeta: isBeta,
                betaNumber: betaNumber,
                isRC: isRC,
                rcNumber: rcNumber,
                components: components,
                sdks: sdks.isEmpty ? nil : sdks,
                minimumOSVersion: minOS
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

    private func extractXIP(_ xipPath: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-xcode-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        sendVerbose("Extracting XIP to \(tempDir.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xip")
        process.arguments = ["--expand", xipPath.path]
        process.currentDirectoryURL = tempDir

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown error"
            cleanup(tempDir)
            throw ScannerError.xipExtractionFailed(reason: errorMessage)
        }

        return tempDir
    }

    // MARK: - Xcode.app discovery

    private func findXcodeApp(in directory: URL) throws -> URL {
        let fileManager = FileManager.default

        if let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            // Look for Xcode.app or Xcode-beta.app
            if let app = contents.first(where: {
                $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app"
            }) {
                return app
            }
        }

        throw ScannerError.xcodeAppNotFound(reason: "No Xcode.app or Xcode-beta.app found in extracted archive")
    }

    // MARK: - Version metadata

    private func extractMinimumOSVersion(from xcodeApp: URL) -> String? {
        let infoPlist = xcodeApp.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any],
              let minOS = plist["LSMinimumSystemVersion"] as? String else {
            return nil
        }
        return minOS
    }

    private func extractVersionMetadata(from xcodeApp: URL) throws -> (osVersion: String, buildNumber: String) {
        let versionPlist = xcodeApp.appendingPathComponent("Contents/version.plist")

        guard let data = try? Data(contentsOf: versionPlist),
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

    // MARK: - Toolchain component extraction

    private func extractToolchainComponents(from xcodeApp: URL) -> [Component] {
        var components: [Component] = []
        let developerDir = xcodeApp.appendingPathComponent("Contents/Developer")
        let toolchainDir = developerDir.appendingPathComponent(
            "Toolchains/XcodeDefault.xctoolchain"
        )

        // Extract toolchain components (clang, swift, ld, etc.)
        let total = toolchainComponents.count + developerComponents.count

        for (index, definition) in toolchainComponents.enumerated() {
            sendProgress(.scanningToolchain(
                component: definition.name,
                current: index + 1,
                total: total
            ))

            let binaryPath = toolchainDir.appendingPathComponent(definition.path)
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

        // Extract developer directory components (git, make, etc.)
        for (index, definition) in developerComponents.enumerated() {
            sendProgress(.scanningToolchain(
                component: definition.name,
                current: toolchainComponents.count + index + 1,
                total: total
            ))

            let binaryPath = developerDir.appendingPathComponent(definition.path)
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

        if components.isEmpty {
            Self.logger.warning("No toolchain components extracted — check Xcode.app structure")
        } else {
            Self.logger.info("Extracted \(components.count) toolchain components")
        }
        return components
    }

    // MARK: - Framework component extraction

    private func extractFrameworkComponents(from xcodeApp: URL) -> [Component] {
        var components: [Component] = []

        // lldb — version is in LLDB.framework, not the lldb binary
        for definition in frameworkComponents {
            let binaryPath = xcodeApp.appendingPathComponent(definition.path)
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

        // Python — path contains version number, need to glob
        let pythonFramework = xcodeApp.appendingPathComponent(
            "Contents/Developer/Library/Frameworks/Python3.framework/Versions"
        )
        if let pythonComponent = extractPythonVersion(from: pythonFramework) {
            components.append(pythonComponent)
        }

        return components
    }

    private func extractPythonVersion(from versionsDir: URL) -> Component? {
        let fileManager = FileManager.default
        guard let versions = try? fileManager.contentsOfDirectory(
            at: versionsDir, includingPropertiesForKeys: nil
        ) else {
            sendVerbose("Python: framework not found at \(versionsDir.path)")
            return nil
        }

        // Find libpython*.dylib in each version directory
        for versionDir in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let libDir = versionDir.appendingPathComponent("lib")
            guard let libs = try? fileManager.contentsOfDirectory(
                at: libDir, includingPropertiesForKeys: nil
            ) else { continue }

            if let dylib = libs.first(where: {
                $0.lastPathComponent.hasPrefix("libpython3") && $0.pathExtension == "dylib"
            }) {
                guard let data = try? Data(contentsOf: dylib) else { continue }

                let relativePath = "Library/Frameworks/Python3.framework/Versions/"
                    + "\(versionDir.lastPathComponent)/lib/\(dylib.lastPathComponent)"
                let definition = ComponentDefinition(
                    name: "Python",
                    path: relativePath,
                    source: .filesystem,
                    // Match "3.x.y" where x >= 2 — avoids "3.0.0" false positives from format versions
                    pattern: #"3\.[2-9][0-9]*\.[0-9]+"#,
                    normalize: { $0 },
                    strategy: .regex
                )

                if let component = ComponentExtractor.extract(from: data, using: definition) {
                    return component
                }
            }
        }

        sendVerbose("Python: no libpython dylib found")
        return nil
    }

    // MARK: - SDK metadata parsing

    private func parseSDKMetadata(from xcodeApp: URL) -> [SDKInfo] {
        let sdksDir = xcodeApp.appendingPathComponent(
            "Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs"
        )
        return SDKMetadataParser.findMacOSSDKs(in: sdksDir)
    }

    private func extractSDKComponents(from xcodeApp: URL) -> [Component] {
        let sdkUsrDir = xcodeApp.appendingPathComponent(
            "Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr"
        )
        guard FileManager.default.fileExists(atPath: sdkUsrDir.path) else {
            sendVerbose("SDK usr/ directory not found")
            return []
        }
        return SDKMetadataParser.extractSDKComponents(from: sdkUsrDir)
    }

    // MARK: - Cleanup

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Progress

    private func sendProgress(_ progress: ScanProgress) {
        onProgress?(progress)
    }

    private func sendVerbose(_ message: String) {
        onVerbose?(message)
    }
}
