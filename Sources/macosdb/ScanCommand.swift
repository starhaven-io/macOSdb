import ArgumentParser
import Foundation
import macOSdbKit

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan an IPSW firmware file and extract component versions."
    )

    @Argument(help: "Path to the .ipsw file to scan.")
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

    @Flag(name: .long, help: "Update the releases.json index alongside the output directory.")
    var updateIndex = false

    @Flag(name: .long, help: "Print verbose diagnostic output to stderr.")
    var verbose = false

    func validate() throws {
        if updateIndex && releaseDate == nil {
            throw ValidationError("--release-date is required when using --update-index")
        }
    }

    func run() async throws {
        let ipswURL = URL(fileURLWithPath: ipswPath)

        guard FileManager.default.fileExists(atPath: ipswURL.path) else {
            printError("IPSW file not found: \(ipswPath)")
            throw ExitCode.failure
        }

        printStatus("macosdb scanner (v\(scannerVersion))")
        printStatus("IPSW: \(ipswURL.lastPathComponent)")
        printStatus("")

        let scanner = IPSWScanner()
        await configureProgress(scanner)
        if verbose {
            await scanner.setVerbose { message in
                self.printStatus("[verbose] \(message)")
            }
        }

        let release = try await performScan(scanner: scanner, ipswURL: ipswURL)
        try writeOutput(release: release)
    }

    // MARK: - Scan pipeline

    private func configureProgress(_ scanner: IPSWScanner) async {
        await scanner.setProgress { progress in
            switch progress {
            case .extractingIPSW:
                printStatus("Extracting IPSW archive...")
            case .parsingKernels(let count):
                printStatus("Parsing \(count) kernelcache files...")
            case .decryptingAEA:
                printStatus("Decrypting AEA (fetching key from Apple)...")
            case .mountingDMG:
                printStatus("Mounting system DMG...")
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
            }
        }
    }

    private func performScan(scanner: IPSWScanner, ipswURL: URL) async throws -> Release {
        do {
            return try await scanner.scan(
                ipswPath: ipswURL,
                releaseName: releaseName,
                releaseDate: releaseDate,
                isBeta: (beta || betaNumber != nil) ? true : nil,
                betaNumber: betaNumber,
                isRC: rc || rcNumber != nil,
                rcNumber: rcNumber
            )
        } catch {
            printError("Scan failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    private func writeOutput(release: Release) throws {
        printStatus("")
        printStatus("=== Results ===")
        printStatus("Release: \(release.displayName) (\(release.buildNumber))")
        printStatus("Kernels: \(release.kernels.count)")
        printStatus("Components: \(release.components.count)")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let jsonData = try encoder.encode(release)

        let outputDir = output.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let filename = "macOS-\(release.osVersion)-\(release.buildNumber).json"
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
        // Index lives alongside the output directory (e.g. data/releases.json for data/releases/)
        // because dataFile paths include the output directory name (e.g. "releases/15/...")
        let indexPath = outputDir.deletingLastPathComponent().appendingPathComponent("releases.json")
        let filename = "macOS-\(release.osVersion)-\(release.buildNumber).json"
        let majorVersion = release.osVersion.split(separator: ".").first.map(String.init) ?? release.osVersion

        var entries: [ReleaseIndexEntry] = []

        if FileManager.default.fileExists(atPath: indexPath.path),
           let data = try? Data(contentsOf: indexPath) {
            entries = (try? JSONDecoder().decode([ReleaseIndexEntry].self, from: data)) ?? []
        }

        entries.removeAll { $0.buildNumber == release.buildNumber }

        let entry = ReleaseIndexEntry(
            osVersion: release.osVersion,
            buildNumber: release.buildNumber,
            releaseName: release.releaseName,
            releaseDate: release.releaseDate,
            isBeta: release.isBeta,
            betaNumber: release.betaNumber,
            isRC: release.isRC,
            rcNumber: release.rcNumber,
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
        let indexData = try encoder.encode(entries)
        try indexData.write(to: indexPath)

        printStatus("Updated index: \(indexPath.path) (\(entries.count) releases)")
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
