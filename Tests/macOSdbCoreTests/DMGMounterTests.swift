import Foundation
import Testing

@testable import macOSdbCore

@Suite("DMG mounter tests")
struct DMGMounterTests {

    @Test("Parses the mounted entity from hdiutil plist output")
    func parsesMountedEntity() async throws {
        let data = try plistData([
            "system-entities": [
                ["dev-entry": "/dev/disk4"],
                ["dev-entry": "/dev/disk4s1", "mount-point": "/Volumes/System"]
            ]
        ])

        let mount = try await DMGMounter().parseMountOutput(data, dmgPath: "/tmp/System.dmg")

        #expect(mount.path == "/Volumes/System")
        #expect(mount.deviceNode == "/dev/disk4s1")
    }

    @Test("Falls back to the image device for an entity without a device node")
    func fallsBackToImageDevice() async throws {
        let data = try plistData([
            "system-entities": [
                ["dev-entry": "/dev/disk5"],
                ["mount-point": "/Volumes/Cryptex"]
            ]
        ])

        let mount = try await DMGMounter().parseMountOutput(data, dmgPath: "/tmp/Cryptex.dmg")

        #expect(mount.path == "/Volumes/Cryptex")
        #expect(mount.deviceNode == "/dev/disk5")
    }

    @Test("Rejects malformed and mountless hdiutil output")
    func rejectsInvalidOutput() async throws {
        let invalidOutputs = [
            Data("not a plist".utf8),
            try plistData(["unexpected": true]),
            try plistData(["system-entities": [["dev-entry": "/dev/disk6"]]])
        ]

        for data in invalidOutputs {
            do {
                _ = try await DMGMounter().parseMountOutput(data, dmgPath: "/tmp/Invalid.dmg")
                Issue.record("Expected invalid hdiutil output to fail")
            } catch ScannerError.dmgMountFailed(let path, _) {
                #expect(path == "/tmp/Invalid.dmg")
            } catch {
                Issue.record("Expected a DMG mount failure, got \(error)")
            }
        }
    }

    private func plistData(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
    }
}
