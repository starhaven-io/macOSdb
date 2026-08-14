import Foundation
import macOSdbCore
import Testing

@testable import macosdb

@Suite("ScanCommand parsing and validation")
struct ScanCommandTests {

    // MARK: - Argument parsing

    @Test("Parses required archive path with defaults")
    func parsesArchivePathWithDefaults() throws {
        let cmd = try ScanCommand.parse(["archive.ipsw"])
        #expect(cmd.archivePath == "archive.ipsw")
        #expect(cmd.output == nil)
        #expect(cmd.releaseName == nil)
        #expect(cmd.releaseDate == nil)
        #expect(cmd.beta == false)
        #expect(cmd.betaNumber == nil)
        #expect(cmd.betaRevision == nil)
        #expect(cmd.rc == false)
        #expect(cmd.rcNumber == nil)
        #expect(cmd.downloadURL == nil)
        #expect(cmd.deviceSpecific == false)
        #expect(cmd.updateIndex == false)
        #expect(cmd.saveAeaKey == false)
        #expect(cmd.aeaKeyPath == nil)
        #expect(cmd.keyOnly == false)
        #expect(cmd.verbose == false)
    }

    @Test("Parses all options together")
    func parsesAllOptions() throws {
        let cmd = try ScanCommand.parse([
            "archive.ipsw",
            "--output", "/tmp/out",
            "--release-name", "Sequoia",
            "--release-date", "2025-07-07",
            "--beta",
            "--beta-number", "3",
            "--beta-revision", "2",
            "--ipsw-url", "https://example.com/x.ipsw",
            "--device-specific",
            "--update-index",
            "--save-aea-key",
            "--aea-key", "/path/to/key.pem",
            "--verbose"
        ])
        #expect(cmd.archivePath == "archive.ipsw")
        #expect(cmd.output == "/tmp/out")
        #expect(cmd.releaseName == "Sequoia")
        #expect(cmd.releaseDate == "2025-07-07")
        #expect(cmd.beta == true)
        #expect(cmd.betaNumber == 3)
        #expect(cmd.betaRevision == 2)
        #expect(cmd.downloadURL == "https://example.com/x.ipsw")
        #expect(cmd.deviceSpecific == true)
        #expect(cmd.updateIndex == true)
        #expect(cmd.saveAeaKey == true)
        #expect(cmd.aeaKeyPath == "/path/to/key.pem")
        #expect(cmd.verbose == true)
    }

    @Test("--xip-url is an alias for the download URL option")
    func xipUrlAlias() throws {
        let cmd = try ScanCommand.parse(["archive.xip", "--xip-url", "https://example.com/x.xip"])
        #expect(cmd.downloadURL == "https://example.com/x.xip")
    }

    @Test("Missing archive path is rejected")
    func missingArchivePathRejected() {
        #expect(throws: (any Error).self) {
            _ = try ScanCommand.parse([])
        }
    }

    @Test("Unknown flag is rejected")
    func unknownFlagRejected() {
        #expect(throws: (any Error).self) {
            _ = try ScanCommand.parse(["archive.ipsw", "--bogus-flag"])
        }
    }

    // MARK: - validate()
    //
    // Note: ArgumentParser's `parse(_:)` calls `validate()` automatically,
    // so validation failures surface as parse errors here.

    @Test("Parse succeeds without --update-index")
    func validateWithoutUpdateIndex() throws {
        _ = try ScanCommand.parse(["archive.ipsw"])
    }

    @Test("Parse succeeds when --update-index has --release-date")
    func validateUpdateIndexWithReleaseDate() throws {
        _ = try ScanCommand.parse([
            "archive.ipsw",
            "--update-index",
            "--release-date", "2025-07-07"
        ])
    }

    @Test("Parse rejects --update-index without --release-date")
    func validateRejectsUpdateIndexWithoutReleaseDate() {
        #expect(throws: (any Error).self) {
            _ = try ScanCommand.parse(["archive.ipsw", "--update-index"])
        }
    }

    @Test("Parse rejects --beta-revision without --beta-number")
    func validateRejectsBetaRevisionWithoutNumber() {
        #expect(throws: (any Error).self) {
            _ = try ScanCommand.parse(["archive.ipsw", "--beta-revision", "2"])
        }
    }

    @Test("Parse rejects a first beta revision")
    func validateRejectsFirstBetaRevision() {
        #expect(throws: (any Error).self) {
            _ = try ScanCommand.parse([
                "archive.ipsw",
                "--beta-number", "3",
                "--beta-revision", "1"
            ])
        }
    }

    // MARK: - Index updates

    private func makeIndexWorkspace() throws -> (root: URL, outputDir: URL, indexPath: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-index-\(UUID().uuidString)", isDirectory: true)
        let outputDir = root.appendingPathComponent("releases", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        return (root, outputDir, root.appendingPathComponent("releases.json"))
    }

    @Test("--update-index refuses to rewrite a corrupt index")
    func updateIndexRefusesCorruptIndex() throws {
        let (root, outputDir, indexPath) = try makeIndexWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let corrupt = "{not valid json"
        try Data(corrupt.utf8).write(to: indexPath)

        let cmd = try ScanCommand.parse(["archive.ipsw"])
        let release = Release(osVersion: "15.0", buildNumber: "24A335", releaseName: "Sequoia")

        #expect(throws: (any Error).self) {
            try cmd.updateReleasesIndex(release: release, outputDir: outputDir)
        }
        #expect(try String(contentsOf: indexPath, encoding: .utf8) == corrupt)
    }

    @Test("--update-index merges and replaces same-build entries")
    func updateIndexMergesExistingEntries() throws {
        let (root, outputDir, indexPath) = try makeIndexWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = [
            ReleaseIndexEntry(
                osVersion: "15.0",
                buildNumber: "24A335",
                releaseName: "Sequoia",
                dataFile: "releases/15/macOS-15.0-24A335.json"
            ),
            ReleaseIndexEntry(
                osVersion: "15.1",
                buildNumber: "24B83",
                releaseName: "Sequoia",
                dataFile: "releases/15/macOS-15.1-24B83.json"
            )
        ]
        try JSONEncoder().encode(existing).write(to: indexPath)

        let cmd = try ScanCommand.parse(["archive.ipsw"])
        let rescanned = Release(
            osVersion: "15.1",
            buildNumber: "24B83",
            releaseName: "Sequoia",
            releaseDate: "2024-10-28"
        )
        try cmd.updateReleasesIndex(release: rescanned, outputDir: outputDir)

        let updated = try JSONDecoder().decode(
            [ReleaseIndexEntry].self, from: Data(contentsOf: indexPath)
        )
        #expect(updated.count == 2)
        #expect(updated.map(\.buildNumber) == ["24B83", "24A335"])
        #expect(updated.first?.releaseDate == "2024-10-28")
    }

    @Test("Writes product output into its major-version directory")
    func writesProductOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-output-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cmd = try ScanCommand.parse(["archive.xip", "--output", root.path])
        let release = Release(
            productType: .xcode,
            osVersion: "26.1",
            buildNumber: "17B123",
            releaseName: "Xcode 26.1",
            components: [Component(name: "Swift", version: "6.2.1", path: "/usr/bin/swift")],
            sdks: [SDKInfo(sdkVersion: "26.1", buildVersion: "25B123")]
        )

        try cmd.writeOutput(release: release)

        let output = root.appendingPathComponent("26/Xcode-26.1-17B123.json")
        let data = try Data(contentsOf: output)
        #expect(data.last == 0x0a)
        #expect(try JSONDecoder().decode(Release.self, from: data) == release)
    }

    @Test("AEA key sidecars preserve mtime and are not overwritten")
    func writesAEAKeySidecarOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("fixture.ipsw")
        try Data("archive".utf8).write(to: archive)
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: archive.path)

        let cmd = try ScanCommand.parse(["archive.ipsw"])
        cmd.writeAEAKey("first", for: archive)
        cmd.writeAEAKey("second", for: archive)

        let sidecar = archive.appendingPathExtension("pem")
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "first")
        let sidecarDate = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date
        #expect(sidecarDate == modificationDate)
    }
}
