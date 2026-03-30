import ArgumentParser
import Foundation
import macOSdbKit

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan an IPSW or Xcode .xip and extract component versions."
    )

    @Argument(help: "Path to the archive file (.ipsw, .dmg, or .xip) to scan.")
    var ipswPath: String

    @Option(name: .shortAndLong, help: "Output directory for the JSON file (default: current directory).")
    var output: String?

    @Option(name: .long, help: "Override the release name (e.g. \"Sequoia\").")
    var releaseName: String?

    @Option(name: .long, help: "Release date in ISO 8601 format (e.g. \"2025-07-07\").")
    var releaseDate: String?

    @Flag(name: .long, help: "Force beta flag (auto-detected from build number by default).")
    var beta = false

    @Option(name: .long, help: "Developer beta number (e.g. 3 for \"Developer Beta 3\").")
    var betaNumber: Int?

    @Flag(name: .long, help: "Mark as a Release Candidate.")
    var rc = false

    @Option(name: .long, help: "RC number (e.g. 2 for \"RC 2\"). Omit for just \"RC\".")
    var rcNumber: Int?

    @Option(name: .customLong("ipsw-url"), help: "URL where this IPSW can be downloaded (e.g. Apple CDN URL).")
    var ipswDownloadURL: String?

    @Flag(name: .long, help: "Mark as a device-specific build (e.g. M3 launch build).")
    var deviceSpecific = false

    @Flag(name: .long, help: "Update the releases.json index alongside the output directory.")
    var updateIndex = false

    @Flag(name: .long, help: "Save the AEA decryption key as a .pem sidecar file next to the IPSW.")
    var saveAeaKey = false

    @Option(name: .customLong("aea-key"), help: "Path to a .pem file to use for AEA decryption instead of fetching from Apple's WKMS.")
    var aeaKeyPath: String?

    @Flag(name: .long, help: "Extract only the AEA decryption key without scanning components. Implies --save-aea-key.")
    var keyOnly = false

    @Flag(name: .long, help: "Print verbose diagnostic output to stderr.")
    var verbose = false

    func validate() throws {
        if updateIndex && releaseDate == nil {
            throw ValidationError("--release-date is required when using --update-index")
        }
    }

    func run() async throws {
        let archiveURL = URL(fileURLWithPath: ipswPath)

        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            printError("Archive not found: \(ipswPath)")
            throw ExitCode.failure
        }

        printStatus("macosdb scanner")
        printStatus("Archive: \(archiveURL.lastPathComponent)")
        printStatus("")

        let aeaKeyPEM = try aeaKeyPath.map { path -> String in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                printError("AEA key file not found: \(path)")
                throw ExitCode.failure
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        if keyOnly {
            try await extractKeyOnly(archiveURL: archiveURL)
            return
        }

        let release: Release

        switch archiveURL.pathExtension.lowercased() {
        case "xip":
            release = try await scanXcode(archiveURL: archiveURL)
        default:
            let (scannedRelease, recoveredPEM) = try await scanIPSW(
                archiveURL: archiveURL,
                aeaKeyPEM: aeaKeyPEM
            )
            release = scannedRelease
            if saveAeaKey, let pem = recoveredPEM {
                writeAEAKey(pem, for: archiveURL)
            }
        }

        try writeOutput(release: release)
    }

    // MARK: - IPSW scan pipeline

    private func scanIPSW(archiveURL: URL, aeaKeyPEM: String? = nil) async throws -> (Release, String?) {
        let scanner = IPSWScanner()
        await configureProgress(scanner)
        if verbose {
            await scanner.setVerbose { message in
                self.printStatus("[verbose] \(message)")
            }
        }

        do {
            let release = try await scanner.scan(
                ipswPath: archiveURL,
                releaseName: releaseName,
                releaseDate: releaseDate,
                ipswURL: ipswDownloadURL,
                isBeta: (beta || betaNumber != nil) ? true : nil,
                betaNumber: betaNumber,
                isRC: rc || rcNumber != nil,
                rcNumber: rcNumber,
                isDeviceSpecific: deviceSpecific,
                aeaKeyPEM: aeaKeyPEM
            )
            let aeaKeyPEM = await scanner.aeaPrivateKeyPEM
            return (release, aeaKeyPEM)
        } catch {
            printError("Scan failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    // MARK: - Key-only extraction

    private func extractKeyOnly(archiveURL: URL) async throws {
        let scanner = IPSWScanner()
        await configureProgress(scanner)
        if verbose {
            await scanner.setVerbose { message in
                self.printStatus("[verbose] \(message)")
            }
        }

        do {
            try await scanner.extractAEAKey(ipswPath: archiveURL)
        } catch {
            printError("Key extraction failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard let pem = await scanner.aeaPrivateKeyPEM else {
            printStatus("No AEA key found (IPSW is not AEA-encrypted)")
            return
        }

        writeAEAKey(pem, for: archiveURL)
    }

    // MARK: - Xcode scan pipeline

    private func scanXcode(archiveURL: URL) async throws -> Release {
        let scanner = XcodeScanner()
        await configureProgress(scanner)
        if verbose {
            await scanner.setVerbose { message in
                self.printStatus("[verbose] \(message)")
            }
        }

        do {
            return try await scanner.scan(
                xipPath: archiveURL,
                releaseName: releaseName,
                releaseDate: releaseDate,
                xipURL: ipswDownloadURL,
                isBeta: beta || betaNumber != nil,
                betaNumber: betaNumber,
                isRC: rc || rcNumber != nil,
                rcNumber: rcNumber
            )
        } catch {
            printError("Xcode scan failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    // MARK: - Progress configuration

    private func configureProgress(_ scanner: IPSWScanner) async {
        await scanner.setProgress { progress in
            self.printProgress(progress)
        }
    }

    private func configureProgress(_ scanner: XcodeScanner) async {
        await scanner.setProgress { progress in
            self.printProgress(progress)
        }
    }

    private func printProgress(_ progress: ScanProgress) {
        switch progress {
        case .extractingIPSW:
            printStatus("Extracting IPSW archive...")
        case .parsingKernels(let count):
            printStatus("Parsing \(count) kernelcache files...")
        case .decryptingAEA:
            printStatus("Decrypting AEA (fetching key from Apple)...")
        case .mountingDMG:
            printStatus("Mounting DMG...")
        case .mountingCryptex:
            printStatus("Mounting cryptex DMG...")
        case .scanningFilesystem(let name, let current, let total):
            printStatus("  [\(current)/\(total)] \(name)")
        case .scanningDyldCache(let name, let current, let total):
            printStatus("  [\(current)/\(total)] \(name) (dyld cache)")
        case .unmountingDMG:
            printStatus("Unmounting DMG...")
        case .assemblingResults:
            printStatus("Assembling results...")
        case .complete:
            break
        case .extractingXIP:
            printStatus("Extracting XIP archive...")
        case .scanningToolchain(let name, let current, let total):
            printStatus("  [\(current)/\(total)] \(name) (toolchain)")
        case .parsingSDKMetadata:
            printStatus("Parsing SDK metadata...")
        }
    }

    private func writeOutput(release: Release) throws {
        let productType = release.resolvedProductType

        printStatus("")
        printStatus("=== Results ===")
        printStatus("Release: \(release.displayName) (\(release.buildNumber))")
        if !release.kernels.isEmpty {
            printStatus("Kernels: \(release.kernels.count)")
        }
        printStatus("Components: \(release.components.count)")
        if let sdks = release.sdks {
            printStatus("SDKs: \(sdks.map(\.sdkVersion).joined(separator: ", "))")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var jsonData = try encoder.encode(release)
        jsonData.append(contentsOf: [0x0A]) // trailing newline

        let outputDir = output.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let filename = "\(productType.filePrefix)-\(release.osVersion)-\(release.buildNumber).json"
        let majorVersion = release.osVersion.split(separator: ".").first.map(String.init) ?? release.osVersion
        let versionDir = outputDir.appendingPathComponent(majorVersion)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let outputPath = versionDir.appendingPathComponent(filename)

        try jsonData.write(to: outputPath)
        printStatus("")
        printStatus("Written to: \(outputPath.path)")

        if updateIndex {
            try updateReleasesIndex(release: release, outputDir: outputDir)
        }
    }

    // MARK: - Index management

    private func updateReleasesIndex(release: Release, outputDir: URL) throws {
        let productType = release.resolvedProductType
        // Index lives alongside the output directory (e.g. data/releases.json for data/releases/)
        // because dataFile paths include the output directory name (e.g. "releases/15/...")
        let indexPath = outputDir.deletingLastPathComponent().appendingPathComponent("releases.json")
        let filename = "\(productType.filePrefix)-\(release.osVersion)-\(release.buildNumber).json"
        let majorVersion = release.osVersion.split(separator: ".").first.map(String.init) ?? release.osVersion

        var entries: [ReleaseIndexEntry] = []

        if FileManager.default.fileExists(atPath: indexPath.path),
           let data = try? Data(contentsOf: indexPath) {
            entries = (try? JSONDecoder().decode([ReleaseIndexEntry].self, from: data)) ?? []
        }

        entries.removeAll { $0.buildNumber == release.buildNumber }

        let entry = ReleaseIndexEntry(
            productType: productType,
            osVersion: release.osVersion,
            buildNumber: release.buildNumber,
            releaseName: release.releaseName,
            releaseDate: release.releaseDate,
            isBeta: release.isBeta,
            betaNumber: release.betaNumber,
            isRC: release.isRC,
            rcNumber: release.rcNumber,
            isDeviceSpecific: release.isDeviceSpecific,
            dataFile: "releases/\(majorVersion)/\(filename)"
        )
        entries.append(entry)

        // Sort: newest version first; within same version: releases > RCs > betas
        entries.sort { lhs, rhs in
            let lhsParts = lhs.osVersion.split(separator: ".").compactMap { Int($0) }
            let rhsParts = rhs.osVersion.split(separator: ".").compactMap { Int($0) }
            for idx in 0..<max(lhsParts.count, rhsParts.count) {
                let lhsVal = idx < lhsParts.count ? lhsParts[idx] : 0
                let rhsVal = idx < rhsParts.count ? rhsParts[idx] : 0
                if lhsVal != rhsVal { return lhsVal > rhsVal }
            }
            let lhsRank = lhs.isBeta ? 0 : lhs.isRC ? 1 : 2
            let rhsRank = rhs.isBeta ? 0 : rhs.isRC ? 1 : 2
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return lhs.buildNumber > rhs.buildNumber
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var indexData = try encoder.encode(entries)
        indexData.append(contentsOf: [0x0A]) // trailing newline
        try indexData.write(to: indexPath)

        printStatus("Updated index: \(indexPath.path) (\(entries.count) releases)")
    }

    private func writeAEAKey(_ pem: String, for ipswURL: URL) {
        let sidecarPath = ipswURL.appendingPathExtension("pem")
        guard !FileManager.default.fileExists(atPath: sidecarPath.path) else {
            return
        }
        do {
            try pem.write(to: sidecarPath, atomically: true, encoding: .utf8)
            printStatus("Saved AEA key: \(sidecarPath.lastPathComponent)")
        } catch {
            printError("Failed to save AEA key: \(error.localizedDescription)")
        }
    }

    private func printStatus(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func printError(_ message: String) {
        FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
    }
}

extension IPSWScanner {
    func setProgress(_ callback: @escaping @Sendable (ScanProgress) -> Void) {
        self.onProgress = callback
    }

    func setVerbose(_ callback: @escaping @Sendable (String) -> Void) {
        self.onVerbose = callback
    }
}

extension XcodeScanner {
    func setProgress(_ callback: @escaping @Sendable (ScanProgress) -> Void) {
        self.onProgress = callback
    }

    func setVerbose(_ callback: @escaping @Sendable (String) -> Void) {
        self.onVerbose = callback
    }
}
