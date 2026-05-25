import Foundation
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
}
