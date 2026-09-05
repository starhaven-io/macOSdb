import Foundation
import Testing

@testable import macOSdbCore

@Suite("XcodeScanner tests")
struct XcodeScannerTests {

    @Test("Scans an expanded Xcode app fixture")
    func scansExpandedXcodeApp() async throws {
        let fixture = try ExpandedXcodeFixture()
        defer { fixture.cleanup() }

        let scanner = XcodeScanner()
        let release = try await scanner.scanExpandedDirectory(
            fixture.root,
            sourceFilename: "Xcode_26.1_beta.xip",
            releaseDate: "2026-08-13",
            xipURL: "https://example.com/Xcode_26.1_beta.xip",
            isBeta: true,
            betaNumber: 2,
            betaRevision: 3
        )

        #expect(release.resolvedProductType == .xcode)
        #expect(release.osVersion == "26.1")
        #expect(release.buildNumber == "17B123")
        #expect(release.releaseName == "Xcode 26.1")
        #expect(release.releaseDate == "2026-08-13")
        #expect(release.xipFile == "Xcode_26.1_beta.xip")
        #expect(release.xipURL == "https://example.com/Xcode_26.1_beta.xip")
        #expect(release.isBeta)
        #expect(release.betaNumber == 2)
        #expect(release.betaRevision == 3)
        #expect(release.minimumOSVersion == "15.0")
        #expect(release.sdks == [SDKInfo(sdkVersion: "26.1", buildVersion: "25B123")])

        #expect(release.component(named: "Apple Clang")?.version == "1700.0.13.3")
        #expect(release.component(named: "Swift")?.version == "6.2.1")
        #expect(release.component(named: "Swift")?.path == "/usr/bin/swift")
        #expect(release.component(named: "Git")?.version == "2.50.1")
        #expect(release.component(named: "lldb")?.version == "2100.0.16.4")
        #expect(release.component(named: "Python")?.version == "3.12.0")
        #expect(release.component(named: "libcurl")?.version == "8.10.1")

        let names = release.components.map(\.name)
        #expect(names == names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
    }

    @Test("An expanded Xcode app requires version metadata")
    func expandedXcodeAppRequiresVersionMetadata() async throws {
        let fixture = try ExpandedXcodeFixture(includeVersionMetadata: false)
        defer { fixture.cleanup() }

        do {
            _ = try await XcodeScanner().scanExpandedDirectory(
                fixture.root,
                sourceFilename: "fixture.xip"
            )
            Issue.record("Expected missing version metadata to fail")
        } catch ScannerError.versionPlistNotFound(let reason) {
            #expect(reason.contains("version.plist"))
        } catch {
            Issue.record("Expected missing version metadata, got \(error)")
        }
    }

    @Test("An expanded archive requires an Xcode app")
    func expandedArchiveRequiresXcodeApp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-xcode-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await XcodeScanner().scanExpandedDirectory(
                root,
                sourceFilename: "fixture.xip"
            )
            Issue.record("Expected a missing Xcode app to fail")
        } catch ScannerError.xcodeAppNotFound(let reason) {
            #expect(reason.contains("No Xcode.app"))
        } catch {
            Issue.record("Expected a missing Xcode app, got \(error)")
        }
    }

    @Test("An expanded archive cannot ambiguously select between app bundles")
    func expandedArchiveRejectsMultipleXcodeApps() async throws {
        let fixture = try ExpandedXcodeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Xcode.app"),
            withIntermediateDirectories: true
        )

        do {
            _ = try await XcodeScanner().scanExpandedDirectory(
                fixture.root,
                sourceFilename: "fixture.xip"
            )
            Issue.record("Expected ambiguous Xcode apps to fail")
        } catch ScannerError.xcodeAppNotFound(let reason) {
            #expect(reason.contains("multiple Xcode app"))
        } catch {
            Issue.record("Expected an ambiguous Xcode app error, got \(error)")
        }
    }

    @Test("xipFilename prefers `path` query parameter (services-account portal URL)")
    func xipFilenameFromServicesAccountURL() {
        let url = "https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_26.5_beta_3/Xcode_26.5_beta_3_Apple_silicon.xip"
        #expect(XcodeScanner.xipFilename(fromURLString: url) == "Xcode_26.5_beta_3_Apple_silicon.xip")
    }

    @Test("xipFilename falls back to lastPathComponent for direct CDN URL")
    func xipFilenameFromCDNURL() {
        let url = "https://adcdownload.apple.com/Developer_Tools/Xcode_26/Xcode_26_Universal.xip"
        #expect(XcodeScanner.xipFilename(fromURLString: url) == "Xcode_26_Universal.xip")
    }

    @Test("xipFilename returns nil for nil or invalid input")
    func xipFilenameNilInput() {
        #expect(XcodeScanner.xipFilename(fromURLString: nil) == nil)
        #expect(XcodeScanner.xipFilename(fromURLString: "") == nil)
    }
}

private struct ExpandedXcodeFixture {
    let root: URL

    private var xcodeApp: URL {
        root.appendingPathComponent("Xcode-beta.app", isDirectory: true)
    }

    init(includeVersionMetadata: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-xcode-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: xcodeApp, withIntermediateDirectories: true)

        if includeVersionMetadata {
            try writePlist([
                "CFBundleShortVersionString": "26.1",
                "ProductBuildVersion": "17B123"
            ], to: "Contents/version.plist")
            try writePlist(["LSMinimumSystemVersion": "15.0"], to: "Contents/Info.plist")
        }

        try write(
            "clang-1700.0.13.3",
            to: "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        )
        try write(
            "Swift version 6.2.1",
            to: "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        )
        try write("2.50.1 (Apple Git-155)", to: "Contents/Developer/usr/bin/git")
        try write("lldb-2100.0.16.4", to: "Contents/SharedFrameworks/LLDB.framework/LLDB")
        try write(
            "3.12.0",
            to: "Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.12/lib/libpython3.12.dylib"
        )

        let sdkRoot = "Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        try writeJSON(["Version": "26.1"], to: "\(sdkRoot)/SDKSettings.json")
        try writePlist(
            ["ProductBuildVersion": "25B123"],
            to: "\(sdkRoot)/System/Library/CoreServices/SystemVersion.plist"
        )
        try write(
            "#define LIBCURL_VERSION \"8.10.1\"",
            to: "\(sdkRoot)/usr/include/curl/curlver.h"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ string: String, to relativePath: String) throws {
        try writeData(Data(string.utf8), to: relativePath)
    }

    private func writeJSON(_ object: Any, to relativePath: String) throws {
        try writeData(try JSONSerialization.data(withJSONObject: object), to: relativePath)
    }

    private func writePlist(_ object: Any, to relativePath: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        try writeData(data, to: relativePath)
    }

    private func writeData(_ data: Data, to relativePath: String) throws {
        let path = xcodeApp.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: path)
    }
}
