import ArgumentParser
import Darwin
import Foundation
import macOSdbCore

struct ScanCommand: AsyncParsableCommand, Sendable {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan an IPSW or Xcode .xip and extract component versions."
    )

    @Argument(help: "Path to the archive file (.ipsw or .xip) to scan.")
    var archivePath: String

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

    @Option(name: .long, help: "Replacement revision of a numbered beta (e.g. 2 for \"Developer Beta 3 v.2\").")
    var betaRevision: Int?

    @Flag(name: .long, help: "Mark as a Release Candidate.")
    var rc = false

    @Option(name: .long, help: "RC number (e.g. 2 for \"RC 2\"). Omit for just \"RC\".")
    var rcNumber: Int?

    @Option(name: [.customLong("ipsw-url"), .customLong("xip-url")], help: "URL where this archive can be downloaded (e.g. Apple CDN URL).")
    var downloadURL: String?

    @Flag(name: .long, help: "Mark as a device-specific build, e.g. M3 launch build (IPSW only).")
    var deviceSpecific = false

    @Flag(name: .long, help: "Update the releases.json index alongside the output directory.")
    var updateIndex = false

    @Flag(name: .long, help: "Save the AEA decryption key as a .pem sidecar file next to the IPSW (IPSW only).")
    var saveAeaKey = false

    @Option(name: .customLong("aea-key"), help: "Path to a .pem file for AEA decryption instead of fetching from Apple's WKMS (IPSW only).")
    var aeaKeyPath: String?

    @Flag(name: .long, help: "Extract only the AEA decryption key without scanning components (IPSW only). Implies --save-aea-key.")
    var keyOnly = false

    @Flag(name: .long, help: "Print verbose diagnostic output to stderr.")
    var verbose = false

    func run() async throws {
        do {
            try await SignalCancellation.run(onFirstSignal: { _ in
                printStatus("")
                printStatus("Cancellation requested; cleaning up...")
            }, operation: {
                try await runScan()
            })
        } catch is CancellationError {
            printError("Scan cancelled")
            throw ExitCode.failure
        }
    }

    private func runScan() async throws {
        let archiveURL = URL(fileURLWithPath: archivePath)

        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            printError("Archive not found: \(archivePath)")
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
        case "ipsw":
            let (scannedRelease, recoveredPEM) = try await scanIPSW(
                archiveURL: archiveURL,
                aeaKeyPEM: aeaKeyPEM
            )
            release = scannedRelease
            if saveAeaKey, let pem = recoveredPEM {
                writeAEAKey(pem, for: archiveURL)
            }
        default:
            preconditionFailure("Archive extension was validated before scanning")
        }

        try writeOutput(release: release)
    }

    // MARK: - IPSW scan pipeline

    private func scanIPSW(archiveURL: URL, aeaKeyPEM: String? = nil) async throws -> (Release, String?) {
        let scanner = IPSWScanner()
        await configureProgress(scanner)
        if verbose {
            await scanner.setVerbose { message in
                printStatus("[verbose] \(message)")
            }
        }

        do {
            let release = try await scanner.scan(
                ipswPath: archiveURL,
                releaseName: releaseName,
                releaseDate: releaseDate,
                ipswURL: downloadURL,
                isBeta: (beta || betaNumber != nil) ? true : nil,
                betaNumber: betaNumber,
                betaRevision: betaRevision,
                isRC: rc || rcNumber != nil,
                rcNumber: rcNumber,
                isDeviceSpecific: deviceSpecific,
                aeaKeyPEM: aeaKeyPEM
            )
            let aeaKeyPEM = await scanner.aeaPrivateKeyPEM
            return (release, aeaKeyPEM)
        } catch is CancellationError {
            throw CancellationError()
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
                printStatus("[verbose] \(message)")
            }
        }

        do {
            try await scanner.extractAEAKey(ipswPath: archiveURL)
        } catch is CancellationError {
            throw CancellationError()
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
                printStatus("[verbose] \(message)")
            }
        }

        do {
            return try await scanner.scan(
                xipPath: archiveURL,
                releaseName: releaseName,
                releaseDate: releaseDate,
                xipURL: downloadURL,
                isBeta: beta || betaNumber != nil,
                betaNumber: betaNumber,
                betaRevision: betaRevision,
                isRC: rc || rcNumber != nil,
                rcNumber: rcNumber
            )
        } catch is CancellationError {
            throw CancellationError()
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

    func writeOutput(release: Release) throws {
        let productType = release.resolvedProductType
        guard let dataFile = productType.canonicalDataFile(
            osVersion: release.osVersion,
            buildNumber: release.buildNumber
        ) else {
            throw ValidationError("Scanner returned an invalid version or build identifier")
        }

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
        let filename = URL(fileURLWithPath: dataFile).lastPathComponent
        let majorVersion = URL(fileURLWithPath: dataFile).deletingLastPathComponent().lastPathComponent
        let versionDir = outputDir.appendingPathComponent(majorVersion)
        let preparedIndex = updateIndex ? try prepareReleasesIndex(release: release, outputDir: outputDir) : nil
        if updateIndex {
            try ReleasePublicationValidator.validate(release)
        }
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let outputPath = versionDir.appendingPathComponent(filename)

        let detailExisted = FileManager.default.fileExists(atPath: outputPath.path)
        let previousDetail = detailExisted ? try Data(contentsOf: outputPath) : nil
        try jsonData.write(to: outputPath, options: .atomic)

        do {
            if let preparedIndex {
                try preparedIndex.data.write(to: preparedIndex.path, options: .atomic)
            }
        } catch {
            if let previousDetail {
                try? previousDetail.write(to: outputPath, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: outputPath)
            }
            throw error
        }

        printStatus("")
        printStatus("Written to: \(outputPath.path)")

        if let preparedIndex {
            printStatus("Updated index: \(preparedIndex.path.path) (\(preparedIndex.entryCount) releases)")
        }
    }

}

// MARK: - Argument validation

extension ScanCommand {
    func validate() throws {
        let archiveExtension = URL(fileURLWithPath: archivePath).pathExtension.lowercased()
        guard archiveExtension == "ipsw" || archiveExtension == "xip" else {
            throw ValidationError("Archive must have an .ipsw or .xip extension")
        }
        if updateIndex && releaseDate == nil {
            throw ValidationError("--release-date is required when using --update-index")
        }
        if let releaseDate, !Self.isValidDate(releaseDate) {
            throw ValidationError("--release-date must be a valid ISO 8601 date (YYYY-MM-DD), got '\(releaseDate)'")
        }
        if beta || betaNumber != nil || betaRevision != nil, rc || rcNumber != nil {
            throw ValidationError("Beta and release-candidate options are mutually exclusive")
        }
        if let betaNumber, betaNumber < 1 {
            throw ValidationError("--beta-number must be greater than zero")
        }
        if let rcNumber, rcNumber < 1 {
            throw ValidationError("--rc-number must be greater than zero")
        }
        if betaRevision != nil, betaNumber == nil {
            throw ValidationError("--beta-revision requires --beta-number")
        }
        if let betaRevision, betaRevision < 2 {
            throw ValidationError("--beta-revision must be 2 or greater")
        }
        if keyOnly && updateIndex {
            throw ValidationError("--key-only cannot be combined with --update-index")
        }
        if archiveExtension == "xip", deviceSpecific || saveAeaKey || aeaKeyPath != nil || keyOnly {
            throw ValidationError("AEA key and device-specific options are available only for IPSW archives")
        }
    }

    private static func isValidDate(_ value: String) -> Bool {
        guard value.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = components.date else { return false }
        let resolved = components.calendar?.dateComponents([.year, .month, .day], from: date)
        return resolved?.year == parts[0] && resolved?.month == parts[1] && resolved?.day == parts[2]
    }
}

// MARK: - Index management and key sidecars

extension ScanCommand {
    struct PreparedIndex {
        let path: URL
        let data: Data
        let entryCount: Int
    }

    func updateReleasesIndex(release: Release, outputDir: URL) throws {
        let prepared = try prepareReleasesIndex(release: release, outputDir: outputDir)
        try prepared.data.write(to: prepared.path, options: .atomic)
        printStatus("Updated index: \(prepared.path.path) (\(prepared.entryCount) releases)")
    }

    func prepareReleasesIndex(release: Release, outputDir: URL) throws -> PreparedIndex {
        let productType = release.resolvedProductType
        // Index lives alongside the output directory (e.g. data/releases.json for data/releases/)
        // because dataFile paths include the output directory name (e.g. "releases/15/...")
        let indexPath = outputDir.deletingLastPathComponent().appendingPathComponent("releases.json")
        guard let dataFile = productType.canonicalDataFile(
            osVersion: release.osVersion,
            buildNumber: release.buildNumber
        ) else {
            throw ValidationError("Scanner returned an invalid version or build identifier")
        }

        var entries: [ReleaseIndexEntry] = []

        if FileManager.default.fileExists(atPath: indexPath.path) {
            do {
                let data = try Data(contentsOf: indexPath)
                entries = try JSONDecoder().decode([ReleaseIndexEntry].self, from: data)
            } catch {
                throw ValidationError(
                    "Refusing to rewrite \(indexPath.path): the existing index could not be read"
                        + " (\(error.localizedDescription)). Fix or remove it, then re-run."
                )
            }
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
            betaRevision: release.betaRevision,
            isRC: release.isRC,
            rcNumber: release.rcNumber,
            isDeviceSpecific: release.isDeviceSpecific,
            dataFile: dataFile
        )
        entries.append(entry)

        entries.sort(by: ReleaseIndexEntry.versionDescending)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var indexData = try encoder.encode(entries)
        indexData.append(contentsOf: [0x0A]) // trailing newline
        return PreparedIndex(path: indexPath, data: indexData, entryCount: entries.count)
    }

    func writeAEAKey(_ pem: String, for ipswURL: URL) {
        let sidecarPath = ipswURL.appendingPathExtension("pem")
        let descriptor = open(
            sidecarPath.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        if descriptor < 0, errno == EEXIST {
            return
        }
        guard descriptor >= 0 else {
            printError("Failed to save AEA key: \(String(cString: strerror(errno)))")
            return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(pem.utf8))
            try handle.synchronize()
            try handle.close()
            if let mtime = (try? FileManager.default.attributesOfItem(atPath: ipswURL.path))?[.modificationDate] as? Date {
                try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: sidecarPath.path)
            }
            printStatus("Saved AEA key: \(sidecarPath.lastPathComponent)")
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: sidecarPath)
            printError("Failed to save AEA key: \(error.localizedDescription)")
        }
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
