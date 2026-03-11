import Foundation
import Testing

@testable import macOSdbKit

@Suite("DataProvider tests")
struct DataProviderTests {

    @Test("ReleaseIndexEntry round-trip encoding")
    func indexEntryRoundTrip() throws {
        let entry = ReleaseIndexEntry(
            osVersion: "15.6.1",
            buildNumber: "24G90",
            releaseName: "Sequoia",
            releaseDate: "2025-07-07",
            dataFile: "releases/15/macOS-15.6.1-24G90.json"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ReleaseIndexEntry.self, from: data)

        #expect(decoded.osVersion == entry.osVersion)
        #expect(decoded.buildNumber == entry.buildNumber)
        #expect(decoded.releaseName == entry.releaseName)
        #expect(decoded.releaseDate == entry.releaseDate)
        #expect(decoded.dataFile == entry.dataFile)
    }

    @Test("Release round-trip encoding")
    func releaseRoundTrip() throws {
        let release = Release(
            osVersion: "15.6.1",
            buildNumber: "24G90",
            releaseName: "Sequoia",
            releaseDate: "2025-07-07",
            scannerVersion: "1.0.0",
            kernels: [
                KernelInfo(
                    file: "kernelcache.release.Mac16,1",
                    darwinVersion: "24.6.0",
                    arch: "ARM64_T8132",
                    chip: "M4",
                    devices: ["Mac16,1"]
                )
            ],
            components: [
                Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                Component(name: "OpenSSH", version: "9.9p2", path: "/usr/bin/ssh")
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(release)
        let decoded = try JSONDecoder().decode(Release.self, from: data)

        #expect(decoded.osVersion == release.osVersion)
        #expect(decoded.buildNumber == release.buildNumber)
        #expect(decoded.releaseName == "Sequoia")
        #expect(decoded.scannerVersion == "1.0.0")
        #expect(decoded.kernels.count == 1)
        #expect(decoded.components.count == 2)
        #expect(decoded.kernels[0].chip == "M4")
        #expect(decoded.components[0].name == "curl")
        #expect(decoded.components[0].version == "8.7.1")
        #expect(decoded.components[1].name == "OpenSSH")
        #expect(decoded.components[1].version == "9.9p2")
    }

    @Test("Release round-trip preserves component source")
    func releaseRoundTripComponentSource() throws {
        let release = Release(
            osVersion: "15.6.1",
            buildNumber: "24G90",
            releaseName: "Sequoia",
            components: [
                Component(
                    name: "libcurl", version: "8.7.1",
                    path: "/usr/lib/libcurl.4.dylib",
                    source: .dyldCache
                )
            ]
        )

        let data = try JSONEncoder().encode(release)
        let decoded = try JSONDecoder().decode(Release.self, from: data)

        #expect(decoded.components[0].source == .dyldCache)
    }

    @Test("DataProviderError has descriptive message")
    func errorDescription() {
        let error = DataProviderError.httpError(
            statusCode: 404,
            url: URL(string: "https://example.com/data.json")!
        )
        #expect(error.errorDescription?.contains("404") == true)
    }

    @Test("Decode fixture release index")
    func decodeFixtureIndex() throws {
        let url = Bundle.module.url(
            forResource: "releases", withExtension: "json", subdirectory: "Fixtures"
        )!
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode([ReleaseIndexEntry].self, from: data)

        #expect(index.count == 2)
        #expect(index[0].osVersion == "14.6.1")
        #expect(index[1].osVersion == "15.6.1")
    }
}
