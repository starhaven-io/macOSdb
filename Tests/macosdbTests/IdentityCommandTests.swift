import ArgumentParser
import Foundation
import Testing
import ZIPFoundation

@testable import macosdb

@Suite("IdentityCommand")
struct IdentityCommandTests {
    @Test("Requires the expected version and build")
    func requiresExpectations() {
        #expect(throws: (any Error).self) {
            _ = try IdentityCommand.parse(["archive.ipsw"])
        }
        #expect(throws: (any Error).self) {
            _ = try IdentityCommand.parse(["archive.ipsw", "--expected-version", "15.6.1"])
        }
    }

    @Test("Accepts an IPSW whose metadata records the expected release")
    func acceptsMatchingIdentity() async throws {
        let archive = try makeIPSW()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let command = try IdentityCommand.parse([
            archive.path, "--expected-version", "15.6.1", "--expected-build", "24G90"
        ])
        try await command.run()
    }

    @Test("Rejects an IPSW whose metadata records another release")
    func rejectsMismatchedIdentity() async throws {
        let archive = try makeIPSW()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let command = try IdentityCommand.parse([
            archive.path, "--expected-version", "27.0", "--expected-build", "26A123"
        ])
        await #expect(throws: ExitCode.failure) {
            try await command.run()
        }
    }

    private func makeIPSW() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-identity-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("UniversalMac_27.0_26A123_Restore.ipsw")
        let manifest = try PropertyListSerialization.data(
            fromPropertyList: ["ProductVersion": "15.6.1", "ProductBuildVersion": "24G90"],
            format: .xml,
            options: 0
        )
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(
            with: "BuildManifest.plist",
            type: .file,
            uncompressedSize: Int64(manifest.count),
            compressionMethod: .none,
            provider: { position, size in
                manifest.subdata(in: Int(position)..<(Int(position) + size))
            }
        )
        return archiveURL
    }
}
