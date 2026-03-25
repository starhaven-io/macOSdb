import Foundation
import Testing

@testable import macOSdbKit

@Suite("SDK metadata parser tests")
struct SDKMetadataParserTests {

    // MARK: - parseSDKSettingsJSON

    @Test("Parse valid SDKSettings.json")
    func parseValidSDKSettings() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let json = """
        {
            "Version": "15.2",
            "CanonicalName": "macosx15.2",
            "MaximumDeploymentTarget": "15.2.99"
        }
        """
        let settingsPath = tempDir.appendingPathComponent("SDKSettings.json")
        try json.write(to: settingsPath, atomically: true, encoding: .utf8)

        let sdk = SDKMetadataParser.parseSDKSettingsJSON(at: settingsPath)
        #expect(sdk != nil)
        #expect(sdk?.sdkVersion == "15.2")
    }

    @Test("Parse SDKSettings.json missing Version key returns nil")
    func parseMissingVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let json = """
        {
            "CanonicalName": "macosx15.2"
        }
        """
        let settingsPath = tempDir.appendingPathComponent("SDKSettings.json")
        try json.write(to: settingsPath, atomically: true, encoding: .utf8)

        let sdk = SDKMetadataParser.parseSDKSettingsJSON(at: settingsPath)
        #expect(sdk == nil)
    }

    @Test("Parse nonexistent file returns nil")
    func parseNonexistentFile() {
        let sdk = SDKMetadataParser.parseSDKSettingsJSON(
            at: URL(fileURLWithPath: "/nonexistent/SDKSettings.json")
        )
        #expect(sdk == nil)
    }

    @Test("Parse invalid JSON returns nil")
    func parseInvalidJSON() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsPath = tempDir.appendingPathComponent("SDKSettings.json")
        try "not json".write(to: settingsPath, atomically: true, encoding: .utf8)

        let sdk = SDKMetadataParser.parseSDKSettingsJSON(at: settingsPath)
        #expect(sdk == nil)
    }

    // MARK: - findMacOSSDKs

    @Test("Find macOS SDKs in directory tree")
    func findMacOSSDKs() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")

        // Create a realistic SDK directory structure
        let sdk1Dir = tempDir.appendingPathComponent("MacOSX15.2.sdk")
        let sdk2Dir = tempDir.appendingPathComponent("MacOSX15.0.sdk")
        let iosDir = tempDir.appendingPathComponent("iPhoneOS18.0.sdk")

        for dir in [sdk1Dir, sdk2Dir, iosDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write SDK settings files
        try """
        {"Version": "15.2"}
        """.write(to: sdk1Dir.appendingPathComponent("SDKSettings.json"), atomically: true, encoding: .utf8)

        try """
        {"Version": "15.0"}
        """.write(to: sdk2Dir.appendingPathComponent("SDKSettings.json"), atomically: true, encoding: .utf8)

        // iOS SDK should be filtered out (no "MacOSX" in path)
        try """
        {"Version": "18.0"}
        """.write(to: iosDir.appendingPathComponent("SDKSettings.json"), atomically: true, encoding: .utf8)

        let sdks = SDKMetadataParser.findMacOSSDKs(in: tempDir)

        #expect(sdks.count == 2)
        // Sorted by version descending
        #expect(sdks[0].sdkVersion == "15.2")
        #expect(sdks[1].sdkVersion == "15.0")
    }

    @Test("Deduplicates SDKs with same version")
    func deduplicateSDKs() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")

        // Two SDK directories with the same version
        let sdk1Dir = tempDir.appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.2.sdk")
        let sdk2Dir = tempDir.appendingPathComponent("Other/MacOSX15.2.sdk")

        for dir in [sdk1Dir, sdk2Dir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for dir in [sdk1Dir, sdk2Dir] {
            try """
            {"Version": "15.2"}
            """.write(to: dir.appendingPathComponent("SDKSettings.json"), atomically: true, encoding: .utf8)
        }

        let sdks = SDKMetadataParser.findMacOSSDKs(in: tempDir)
        #expect(sdks.count == 1)
        #expect(sdks[0].sdkVersion == "15.2")
    }

    @Test("Empty directory returns empty array")
    func emptyDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sdks = SDKMetadataParser.findMacOSSDKs(in: tempDir)
        #expect(sdks.isEmpty)
    }
}
