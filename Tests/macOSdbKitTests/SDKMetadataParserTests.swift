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

    // MARK: - extractSDKComponents

    @Test("Extract version from #define header")
    func extractDefineVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        let includeDir = tempDir.appendingPathComponent("include")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        #define ZLIB_VERSION "1.2.12"
        #define ZLIB_VERNUM 0x12c0
        """.write(to: includeDir.appendingPathComponent("zlib.h"), atomically: true, encoding: .utf8)

        let components = SDKMetadataParser.extractSDKComponents(from: tempDir)
        let zlib = components.first { $0.name == "zlib" }
        #expect(zlib?.version == "1.2.12")
        #expect(zlib?.source == .sdk)
    }

    @Test("Extract version from #define with extra spaces")
    func extractDefineWithSpaces() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        let includeDir = tempDir.appendingPathComponent("include/curl")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        #  define LIBCURL_VERSION "8.7.1"
        """.write(to: includeDir.appendingPathComponent("curlver.h"), atomically: true, encoding: .utf8)

        let components = SDKMetadataParser.extractSDKComponents(from: tempDir)
        let curl = components.first { $0.name == "libcurl" }
        #expect(curl?.version == "8.7.1")
    }

    @Test("Extract version from .tbd current-version")
    func extractTbdVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        let libDir = tempDir.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        --- !tapi-tbd
        tbd-version:     4
        install-name:    '/usr/lib/libbz2.1.0.dylib'
        current-version: 1.0.8
        compatibility-version: 1.0.0
        """.write(to: libDir.appendingPathComponent("libbz2.1.0.tbd"), atomically: true, encoding: .utf8)

        let components = SDKMetadataParser.extractSDKComponents(from: tempDir)
        let bzip2 = components.first { $0.name == "bzip2" }
        #expect(bzip2?.version == "1.0.8")
    }

    @Test("Extract multi-define version for expat")
    func extractExpatVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        let includeDir = tempDir.appendingPathComponent("include")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        #  define XML_MAJOR_VERSION 2
        #  define XML_MINOR_VERSION 7
        #  define XML_MICRO_VERSION 3
        """.write(to: includeDir.appendingPathComponent("expat.h"), atomically: true, encoding: .utf8)

        let components = SDKMetadataParser.extractSDKComponents(from: tempDir)
        let expat = components.first { $0.name == "expat" }
        #expect(expat?.version == "2.7.3")
    }

    @Test("Extract multi-define version for ncurses")
    func extractNcursesVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        let includeDir = tempDir.appendingPathComponent("include")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        #define NCURSES_VERSION_MAJOR 6
        #define NCURSES_VERSION_MINOR 0
        #define NCURSES_VERSION_PATCH 20150808
        """.write(to: includeDir.appendingPathComponent("curses.h"), atomically: true, encoding: .utf8)

        let components = SDKMetadataParser.extractSDKComponents(from: tempDir)
        let ncurses = components.first { $0.name == "ncurses" }
        #expect(ncurses?.version == "6.0.20150808")
    }

    @Test("Extract libffi version from header comment")
    func extractLibffiVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        let includeDir = tempDir.appendingPathComponent("include/ffi")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        /* -----------------------------------------------------------------*-C-*-
           libffi 3.4-rc1
             - Copyright (c) 2011, 2014, 2019, 2021 Anthony Green
        */
        """.write(to: includeDir.appendingPathComponent("ffi.h"), atomically: true, encoding: .utf8)

        let components = SDKMetadataParser.extractSDKComponents(from: tempDir)
        let libffi = components.first { $0.name == "libffi" }
        #expect(libffi?.version == "3.4-rc1")
    }

    @Test("Missing SDK file is skipped gracefully")
    func missingSDKFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let components = SDKMetadataParser.extractSDKComponents(from: tempDir)
        #expect(components.isEmpty)
    }
}
