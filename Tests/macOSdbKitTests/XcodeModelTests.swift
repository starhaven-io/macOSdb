import Foundation
import Testing

@testable import macOSdbKit

@Suite("Xcode model decoding tests")
struct XcodeModelTests {

    // MARK: - ProductType decoding

    @Test("Release decodes productType from JSON")
    func releaseDecodesProductType() throws {
        let json = Data("""
        {
            "productType": "Xcode",
            "osVersion": "26.3",
            "buildNumber": "17C529",
            "releaseName": "Xcode 26.3",
            "components": [],
            "kernels": []
        }
        """.utf8)

        let release = try JSONDecoder().decode(Release.self, from: json)
        #expect(release.productType == .xcode)
        #expect(release.resolvedProductType == .xcode)
    }

    @Test("Release defaults to macOS when productType is missing")
    func releaseDefaultsToMacOS() throws {
        let json = Data("""
        {
            "osVersion": "15.6.1",
            "buildNumber": "24G90",
            "releaseName": "Sequoia",
            "components": [],
            "kernels": []
        }
        """.utf8)

        let release = try JSONDecoder().decode(Release.self, from: json)
        #expect(release.productType == nil)
        #expect(release.resolvedProductType == .macOS)
    }

    @Test("Release decodes sdks field")
    func releaseDecodesSDKs() throws {
        let json = Data("""
        {
            "productType": "Xcode",
            "osVersion": "26.3",
            "buildNumber": "17C529",
            "releaseName": "Xcode 26.3",
            "components": [],
            "sdks": [
                {"sdkVersion": "26.2"},
                {"sdkVersion": "15.0"}
            ]
        }
        """.utf8)

        let release = try JSONDecoder().decode(Release.self, from: json)
        #expect(release.sdks?.count == 2)
        #expect(release.sdks?[0].sdkVersion == "26.2")
        #expect(release.sdks?[1].sdkVersion == "15.0")
    }

    @Test("Release without sdks field decodes as nil")
    func releaseWithoutSDKs() throws {
        let json = Data("""
        {
            "osVersion": "15.6.1",
            "buildNumber": "24G90",
            "releaseName": "Sequoia",
            "components": []
        }
        """.utf8)

        let release = try JSONDecoder().decode(Release.self, from: json)
        #expect(release.sdks == nil)
    }

    @Test("Release decodes sourceFile and sourceURL")
    func releaseDecodesSourceFields() throws {
        let json = Data("""
        {
            "productType": "Xcode",
            "osVersion": "26.3",
            "buildNumber": "17C529",
            "releaseName": "Xcode 26.3",
            "sourceFile": "Xcode_26.3.xip",
            "sourceURL": "https://example.com/Xcode_26.3.xip",
            "components": []
        }
        """.utf8)

        let release = try JSONDecoder().decode(Release.self, from: json)
        #expect(release.sourceFile == "Xcode_26.3.xip")
        #expect(release.sourceURL == "https://example.com/Xcode_26.3.xip")
    }

    @Test("ReleaseIndexEntry decodes productType")
    func indexEntryDecodesProductType() throws {
        let json = Data("""
        [{
            "productType": "Xcode",
            "osVersion": "26.3",
            "buildNumber": "17C529",
            "releaseName": "Xcode 26.3",
            "dataFile": "releases/26/Xcode-26.3-17C529.json"
        }]
        """.utf8)

        let entries = try JSONDecoder().decode([ReleaseIndexEntry].self, from: json)
        #expect(entries[0].productType == .xcode)
        #expect(entries[0].resolvedProductType == .xcode)
    }

    @Test("ReleaseIndexEntry defaults to macOS when productType missing")
    func indexEntryDefaultsToMacOS() throws {
        let json = Data("""
        [{
            "osVersion": "15.6.1",
            "buildNumber": "24G90",
            "releaseName": "Sequoia",
            "dataFile": "releases/15/macOS-15.6.1-24G90.json"
        }]
        """.utf8)

        let entries = try JSONDecoder().decode([ReleaseIndexEntry].self, from: json)
        #expect(entries[0].productType == nil)
        #expect(entries[0].resolvedProductType == .macOS)
    }

    // MARK: - Display name by product type

    @Test("Xcode displayName format")
    func xcodeDisplayName() {
        let release = Release(
            productType: .xcode, osVersion: "26.3", buildNumber: "17C529", releaseName: "Xcode 26.3"
        )
        #expect(release.displayName == "Xcode 26.3")
    }

    @Test("Xcode beta displayName includes beta label")
    func xcodeBetaDisplayName() {
        let release = Release(
            productType: .xcode, osVersion: "26.4", buildNumber: "17E192",
            releaseName: "Xcode 26.4", isBeta: true, betaNumber: 2
        )
        #expect(release.displayName == "Xcode 26.4 Developer Beta 2")
    }
}
