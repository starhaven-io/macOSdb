import Testing

@testable import macosdb

@Suite("ScanCommand Xcode archive validation")
struct ScanCommandXcodeArchiveTests {
    @Test("Parse accepts an Xcode AEA archive")
    func acceptsXcodeAEA() throws {
        let cmd = try ScanCommand.parse(["Xcode_27.3_beta.aea"])
        #expect(cmd.archivePath == "Xcode_27.3_beta.aea")
    }

    @Test("Parse rejects IPSW-only options for Xcode archives", arguments: ["archive.xip", "archive.aea"])
    func rejectsIPSWOptions(archive: String) {
        for option in ["--device-specific", "--save-aea-key", "--key-only"] {
            #expect(throws: (any Error).self) {
                _ = try ScanCommand.parse([archive, option])
            }
        }
        #expect(throws: (any Error).self) {
            _ = try ScanCommand.parse([archive, "--aea-key", "key.pem"])
        }
    }

    @Test("Parse rejects --update-index for an Xcode AEA archive, even with a XIP source URL")
    func rejectsUpdateIndexForXcodeAEA() throws {
        let publication = [
            "--update-index",
            "--release-date", "2026-11-03",
            "--xip-url",
            "https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_27.3_beta/Xcode_27.3_beta.xip"
        ]
        _ = try ScanCommand.parse(["archive.xip"] + publication)
        for archive in ["archive.aea", "archive.AEA"] {
            #expect(throws: (any Error).self) {
                _ = try ScanCommand.parse([archive] + publication)
            }
        }
    }
}
