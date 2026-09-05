import Foundation
import Testing
import ZIPFoundation

@testable import macosdb

@Suite("ValidateCommand parsing and validation")
struct ValidateCommandTests {

    // MARK: - Argument parsing and validation
    //
    // Note: ArgumentParser's `parse(_:)` calls `validate()` automatically,
    // so validation failures surface as parse errors here.

    @Test("Parses multiple archive paths")
    func parsesMultipleArchives() throws {
        let cmd = try ValidateCommand.parse(["a.ipsw", "b.ipsw", "c.xip"])
        #expect(cmd.archivePaths == ["a.ipsw", "b.ipsw", "c.xip"])
        #expect(cmd.dir == nil)
        #expect(cmd.rehash == false)
    }

    @Test("Parses --dir and --rehash")
    func parsesDirAndRehash() throws {
        let cmd = try ValidateCommand.parse(["--dir", "/tmp/archives", "--rehash"])
        #expect(cmd.dir == "/tmp/archives")
        #expect(cmd.rehash == true)
    }

    @Test("Parse succeeds with at least one archive path")
    func validateWithArchivePath() throws {
        _ = try ValidateCommand.parse(["a.ipsw"])
    }

    @Test("Parse succeeds with --dir")
    func validateWithDir() throws {
        _ = try ValidateCommand.parse(["--dir", "/tmp/archives"])
    }

    @Test("Parse rejects empty inputs")
    func validateRejectsEmpty() {
        #expect(throws: (any Error).self) {
            _ = try ValidateCommand.parse([])
        }
    }

    @Test("Archive handles reject links and detect pathname replacement")
    func archiveIdentityIsStable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-validate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("archive.xip")
        try Data("original".utf8).write(to: archiveURL)
        let opened = try OpenedArchive(url: archiveURL)

        let linkURL = directory.appendingPathComponent("link.xip")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: archiveURL)
        #expect(throws: (any Error).self) {
            _ = try OpenedArchive(url: linkURL)
        }

        let previousURL = directory.appendingPathComponent("previous.xip")
        try FileManager.default.moveItem(at: archiveURL, to: previousURL)
        try Data("replacement".utf8).write(to: archiveURL)
        #expect(throws: OpenedArchiveError.self) {
            try opened.ensurePathStillReferencesOpenedFile()
        }
    }

    @Test("ZIP validation can read the already-open archive descriptor")
    func archiveDescriptorCanBeReopened() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-validate-zip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("archive.ipsw")
        let zip = try Archive(url: archiveURL, accessMode: .create)
        let contents = Data("fixture".utf8)
        try zip.addEntry(
            with: "fixture.txt",
            type: .file,
            uncompressedSize: Int64(contents.count),
            provider: { position, size in
                let start = Int(position)
                return contents.subdata(in: start..<(start + size))
            }
        )

        let opened = try OpenedArchive(url: archiveURL)
        let reopened = try Archive(url: opened.descriptorURL, accessMode: .read)
        #expect(Array(reopened).count == 1)
    }

    @Test("Checksum sidecars must be bounded regular files")
    func checksumSidecarsAreBoundedRegularFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-validate-sidecar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("archive.xip")
        try Data("archive".utf8).write(to: archiveURL)
        let sidecarURL = archiveURL.appendingPathExtension("sha256")
        let outsideURL = directory.appendingPathComponent("outside")
        try Data(repeating: 0x61, count: 65).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(at: sidecarURL, withDestinationURL: outsideURL)

        let linkedCommand = try ValidateCommand.parse([archiveURL.path])
        var rejectedLink = false
        do {
            try await linkedCommand.run()
        } catch {
            rejectedLink = true
        }
        #expect(rejectedLink)

        try FileManager.default.removeItem(at: sidecarURL)
        try Data(repeating: 0x61, count: 4 * 1_024 + 1).write(to: sidecarURL)
        let oversizedCommand = try ValidateCommand.parse([archiveURL.path])
        var rejectedOversized = false
        do {
            try await oversizedCommand.run()
        } catch {
            rejectedOversized = true
        }
        #expect(rejectedOversized)
    }
}
