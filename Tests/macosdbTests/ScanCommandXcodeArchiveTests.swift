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

    private static let download = "https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_27.3_beta/"

    @Test("--aea-url is an alias for the download URL option")
    func aeaURLAlias() throws {
        let url = Self.download + "Xcode_27.3_beta.aea"
        let cmd = try ScanCommand.parse(["archive.aea", "--aea-url", url])
        #expect(cmd.downloadURL == url)
    }

    @Test("Parse accepts publication when the URL names the scanned format", arguments: [
        ("archive.xip", "Xcode_27.3_beta.xip"),
        ("archive.aea", "Xcode_27.3_beta.aea"),
        ("archive.AEA", "Xcode_27.3_beta.aea")
    ])
    func acceptsMatchingSourceURL(archive: String, file: String) throws {
        _ = try ScanCommand.parse([
            archive, "--update-index", "--release-date", "2026-11-03", "--xip-url", Self.download + file
        ])
    }

    @Test("Parse rejects a download URL that names the other Xcode format", arguments: [
        ("archive.aea", "Xcode_27.3_beta.xip"),
        ("archive.AEA", "Xcode_27.3_beta.xip"),
        ("archive.xip", "Xcode_27.3_beta.aea"),
        ("archive.aea", "download")
    ])
    func rejectsMismatchedSourceURL(archive: String, file: String) {
        #expect(throws: (any Error).self) {
            _ = try ScanCommand.parse([archive, "--aea-url", Self.download + file])
        }
        #expect(throws: (any Error).self) {
            _ = try ScanCommand.parse([
                archive, "--update-index", "--release-date", "2026-11-03", "--xip-url", Self.download + file
            ])
        }
    }
}
