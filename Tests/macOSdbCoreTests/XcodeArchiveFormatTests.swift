import Foundation
import Testing

@testable import macOSdbCore

@Suite("XcodeArchiveFormat tests")
struct XcodeArchiveFormatTests {
    private let workspace = URL(fileURLWithPath: "/workspace/macosdb-xcode-test")

    @Test("The archive extension selects the format, case-insensitively")
    func selectsFormatFromExtension() {
        #expect(XcodeArchiveFormat(archive: URL(fileURLWithPath: "/tmp/Xcode_27.3.xip")) == .xip)
        #expect(XcodeArchiveFormat(archive: URL(fileURLWithPath: "/tmp/Xcode_27.3.aea")) == .aea)
        #expect(XcodeArchiveFormat(archive: URL(fileURLWithPath: "/tmp/Xcode_27.3.AEA")) == .aea)
    }

    @Test("A XIP expands with xip at an absolute path")
    func xipExpansionCommand() throws {
        let archive = URL(fileURLWithPath: "/archive/Xcode-27.3-27C5020n.xip")
        let command = try XcodeArchiveFormat.xip.expansionCommand(for: archive, into: workspace)
        #expect(command.executableURL.path == "/usr/bin/xip")
        #expect(command.arguments == ["--expand", archive.path])
    }

    @Test("An AEA extracts into the workspace with aa and the key the archive names")
    func aeaExpansionCommand() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-aea-command-\(UUID().uuidString).aea")
        defer { try? FileManager.default.removeItem(at: archive) }
        try XcodeAEAFixture.archivePrefix().write(to: archive)

        let command = try XcodeArchiveFormat.aea.expansionCommand(for: archive, into: workspace)
        #expect(command.executableURL.path == "/usr/bin/aa")
        #expect(command.arguments == [
            "extract", "-i", archive.path, "-d", workspace.path,
            "-sign-pub-value", "hex:\(XcodeAEAFixture.p256PublicKeyHex)"
        ])
    }

    @Test("Expansion failures name the format that failed")
    func expansionFailures() {
        #expect(
            XcodeArchiveFormat.xip.expansionFailure(reason: "signature").errorDescription
                == "Failed to extract XIP archive: signature"
        )
        #expect(
            XcodeArchiveFormat.aea.expansionFailure(reason: "signature").errorDescription
                == "Failed to extract Xcode AEA archive: signature"
        )
    }
}
