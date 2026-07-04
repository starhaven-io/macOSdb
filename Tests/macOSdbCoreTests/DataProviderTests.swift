import Foundation
import Testing

@testable import macOSdbCore

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

        let unsafePath = DataProviderError.invalidDataFile("../secret.json")
        #expect(unsafePath.errorDescription?.contains("unsafe path") == true)
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

    @Test("Fetch release index and releases from a local data directory")
    func fetchesLocalData() async throws {
        let dataRoot = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let provider = DataProvider(baseURL: dataRoot)
        let index = try await provider.fetchReleaseIndex()

        #expect(index.count == 4)
        #expect(index[0].osVersion == "15.0")

        let release = try await provider.fetchRelease(index[0])
        #expect(release.osVersion == "15.0")
        #expect(release.components.first?.name == "curl")

        let found = try await provider.findRelease(osVersion: "14.0")
        #expect(found?.buildNumber == "23A344")
    }

    @Test("findRelease prefers universal GA over device-specific duplicate version")
    func findReleasePrefersUniversalRelease() async throws {
        let dataRoot = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let provider = DataProvider(baseURL: dataRoot)
        let release = try await provider.findRelease(osVersion: "15.1")

        #expect(release?.buildNumber == "24B83")
    }

    @Test("DataProvider caches local index and release loads")
    func cachesLocalLoads() async throws {
        let dataRoot = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let provider = DataProvider(baseURL: dataRoot)
        let index = try await provider.fetchReleaseIndex()
        let release = try await provider.fetchRelease(index[0])

        try FileManager.default.removeItem(at: dataRoot.appendingPathComponent("macos"))

        let cachedIndex = try await provider.fetchReleaseIndex()
        let cachedRelease = try await provider.fetchRelease(index[0])

        #expect(cachedIndex == index)
        #expect(cachedRelease == release)
    }

    @Test("DataProvider rejects data files that traverse out of the product directory")
    func rejectsUnsafeDataFile() async throws {
        let dataRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let provider = DataProvider(baseURL: dataRoot)
        let entry = ReleaseIndexEntry(
            osVersion: "15.0",
            buildNumber: "24A335",
            releaseName: "Sequoia",
            dataFile: "../secret.json"
        )

        do {
            _ = try await provider.fetchRelease(entry)
            Issue.record("Expected DataProvider to reject path traversal")
        } catch DataProviderError.invalidDataFile(let path) {
            #expect(path == "../secret.json")
        } catch {
            Issue.record("Expected invalidDataFile, got \(error)")
        }
    }

    @Test("DataProvider rejects nested traversal data files")
    func rejectsNestedTraversalDataFile() async throws {
        let dataRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let provider = DataProvider(baseURL: dataRoot)
        let entry = ReleaseIndexEntry(
            osVersion: "15.0",
            buildNumber: "24A335",
            releaseName: "Sequoia",
            dataFile: "releases/15/../../../etc/hosts"
        )

        do {
            _ = try await provider.fetchRelease(entry)
            Issue.record("Expected DataProvider to reject nested path traversal")
        } catch DataProviderError.invalidDataFile(let path) {
            #expect(path == "releases/15/../../../etc/hosts")
        } catch {
            Issue.record("Expected invalidDataFile, got \(error)")
        }
    }

    @Test("DataProvider treats absolute data files as local product-relative misses")
    func absoluteDataFileDoesNotEscapeDataRoot() async throws {
        let dataRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let provider = DataProvider(baseURL: dataRoot)
        let entry = ReleaseIndexEntry(
            osVersion: "15.0",
            buildNumber: "24A335",
            releaseName: "Sequoia",
            dataFile: "/etc/passwd"
        )

        do {
            _ = try await provider.fetchRelease(entry)
            Issue.record("Expected absolute dataFile fetch to fail under the data root")
        } catch DataProviderError.invalidDataFile {
            Issue.record("Absolute paths should not be treated as traversal")
        } catch {
            #expect(true)
        }
    }

    @Test("DataProvider fetches Xcode index and release data")
    func fetchesXcodeData() async throws {
        let dataRoot = try makeXcodeDataStore()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let provider = DataProvider(baseURL: dataRoot)
        let index = try await provider.fetchReleaseIndex(for: .xcode)
        let release = try await provider.findRelease(osVersion: "16.0", productType: .xcode)

        #expect(index.count == 1)
        #expect(index[0].resolvedProductType == .xcode)
        #expect(release?.buildNumber == "16A242d")
        #expect(release?.resolvedProductType == .xcode)
    }

    @Test("Malformed release JSON throws a decoding error")
    func malformedReleaseJSONThrowsDecodingError() async throws {
        let dataRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-provider-\(UUID().uuidString)", isDirectory: true)
        let releasesDir = dataRoot.appendingPathComponent("macos/releases/15", isDirectory: true)
        try FileManager.default.createDirectory(at: releasesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let releaseFile = releasesDir.appendingPathComponent("macOS-15.0-24A335.json")
        try Data("{ invalid json".utf8).write(to: releaseFile)

        let provider = DataProvider(baseURL: dataRoot)
        let entry = ReleaseIndexEntry(
            osVersion: "15.0",
            buildNumber: "24A335",
            releaseName: "Sequoia",
            dataFile: "releases/15/macOS-15.0-24A335.json"
        )

        do {
            _ = try await provider.fetchRelease(entry)
            Issue.record("Expected malformed release JSON to throw")
        } catch is DecodingError {
            #expect(true)
        } catch {
            Issue.record("Expected DecodingError, got \(error)")
        }
    }

}

private func makeLocalDataStore() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macosdb-provider-\(UUID().uuidString)", isDirectory: true)
    let macosDir = root.appendingPathComponent("macos", isDirectory: true)
    let releases14 = macosDir.appendingPathComponent("releases/14", isDirectory: true)
    let releases15 = macosDir.appendingPathComponent("releases/15", isDirectory: true)
    try FileManager.default.createDirectory(at: releases14, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: releases15, withIntermediateDirectories: true)

    try writeMacOSReleaseIndex(to: macosDir)
    try writeMacOSRelease(
        release(
            version: "15.0",
            build: "24A335",
            name: "Sequoia",
            date: "2024-09-16",
            componentVersion: "8.7.1"
        ),
        to: releases15
    )
    try writeMacOSRelease(
        release(
            version: "14.0",
            build: "23A344",
            name: "Sonoma",
            date: "2023-09-26",
            componentVersion: "8.4.0"
        ),
        to: releases14
    )
    try writeMacOSRelease(
        release(
            version: "15.1",
            build: "24B83",
            name: "Sequoia",
            date: "2024-10-28",
            componentVersion: "8.7.1"
        ),
        to: releases15
    )

    return root
}

private func writeMacOSReleaseIndex(to macosDir: URL) throws {
    let index = [
        ReleaseIndexEntry(
            osVersion: "15.0",
            buildNumber: "24A335",
            releaseName: "Sequoia",
            releaseDate: "2024-09-16",
            dataFile: "releases/15/macOS-15.0-24A335.json"
        ),
        ReleaseIndexEntry(
            osVersion: "14.0",
            buildNumber: "23A344",
            releaseName: "Sonoma",
            releaseDate: "2023-09-26",
            dataFile: "releases/14/macOS-14.0-23A344.json"
        ),
        ReleaseIndexEntry(
            osVersion: "15.1",
            buildNumber: "24B2083",
            releaseName: "Sequoia",
            releaseDate: "2024-10-28",
            isDeviceSpecific: true,
            dataFile: "releases/15/macOS-15.1-24B2083.json"
        ),
        ReleaseIndexEntry(
            osVersion: "15.1",
            buildNumber: "24B83",
            releaseName: "Sequoia",
            releaseDate: "2024-10-28",
            dataFile: "releases/15/macOS-15.1-24B83.json"
        )
    ]
    try writeJSON(index, to: macosDir.appendingPathComponent("releases.json"))
}

private func writeMacOSRelease(_ release: Release, to directory: URL) throws {
    try writeJSON(
        release,
        to: directory.appendingPathComponent("macOS-\(release.osVersion)-\(release.buildNumber).json")
    )
}

private func makeXcodeDataStore() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macosdb-provider-\(UUID().uuidString)", isDirectory: true)
    let xcodeDir = root.appendingPathComponent("xcode", isDirectory: true)
    let releases16 = xcodeDir.appendingPathComponent("releases/16", isDirectory: true)
    try FileManager.default.createDirectory(at: releases16, withIntermediateDirectories: true)

    let index = [
        ReleaseIndexEntry(
            productType: .xcode,
            osVersion: "16.0",
            buildNumber: "16A242d",
            releaseName: "Xcode",
            releaseDate: "2024-09-16",
            dataFile: "releases/16/Xcode-16.0-16A242d.json"
        )
    ]
    try writeJSON(index, to: xcodeDir.appendingPathComponent("releases.json"))
    try writeJSON(
        Release(
            productType: .xcode,
            osVersion: "16.0",
            buildNumber: "16A242d",
            releaseName: "Xcode",
            releaseDate: "2024-09-16",
            components: [
                Component(name: "Swift", version: "6.0", path: "/usr/bin/swift")
            ]
        ),
        to: releases16.appendingPathComponent("Xcode-16.0-16A242d.json")
    )

    return root
}

private func release(
    version: String,
    build: String,
    name: String,
    date: String,
    componentVersion: String
) -> Release {
    Release(
        osVersion: version,
        buildNumber: build,
        releaseName: name,
        releaseDate: date,
        components: [
            Component(name: "curl", version: componentVersion, path: "/usr/bin/curl")
        ]
    )
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: url)
}
