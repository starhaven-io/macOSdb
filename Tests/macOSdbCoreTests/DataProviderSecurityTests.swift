import Foundation
import Testing

@testable import macOSdbCore

@Suite("DataProvider security tests")
struct DataProviderSecurityTests {
    @Test("DataProvider rejects a swapped existing release pointer")
    func rejectsSwappedReleasePointer() async throws {
        let dataRoot = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let provider = DataProvider(baseURL: dataRoot)
        let entry = ReleaseIndexEntry(
            osVersion: "15.0",
            buildNumber: "24A335",
            releaseName: "Sequoia",
            dataFile: "releases/14/macOS-14.0-23A344.json"
        )

        do {
            _ = try await provider.fetchRelease(entry)
            Issue.record("Expected a swapped release pointer to be rejected")
        } catch DataProviderError.invalidDataFile {
            #expect(true)
        } catch {
            Issue.record("Expected invalidDataFile, got \(error)")
        }
    }

    @Test("DataProvider binds detail identity to the index entry")
    func rejectsDetailIdentityMismatch() async throws {
        let dataRoot = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let detail = dataRoot.appendingPathComponent("macos/releases/15/macOS-15.0-24A335.json")
        try writeJSON(
            release(
                version: "15.1",
                build: "24B83",
                name: "Sequoia",
                date: "2024-10-28",
                componentVersion: "8.7.1"
            ),
            to: detail
        )

        let provider = DataProvider(baseURL: dataRoot)
        let entry = try #require(try await provider.fetchReleaseIndex().first)
        await #expect(throws: DataProviderError.self) {
            _ = try await provider.fetchRelease(entry)
        }
    }

    @Test("DataProvider rejects a canonical symlink that escapes the product directory")
    func rejectsEscapingDetailSymlink() async throws {
        let dataRoot = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let detail = dataRoot.appendingPathComponent("macos/releases/15/macOS-15.0-24A335.json")
        let outside = dataRoot.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: detail, to: outside)
        try FileManager.default.createSymbolicLink(at: detail, withDestinationURL: outside)

        let provider = DataProvider(baseURL: dataRoot)
        let entry = try #require(try await provider.fetchReleaseIndex().first)
        await #expect(throws: DataProviderError.self) {
            _ = try await provider.fetchRelease(entry)
        }
    }

    @Test("DataProvider confines a local index to its product directory")
    func rejectsEscapingIndexSymlink() async throws {
        let dataRoot = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let index = dataRoot.appendingPathComponent("macos/releases.json")
        let outside = dataRoot.appendingPathComponent("outside-index.json")
        try FileManager.default.moveItem(at: index, to: outside)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outside)

        let provider = DataProvider(baseURL: dataRoot)
        await #expect(throws: DataProviderError.self) {
            _ = try await provider.fetchReleaseIndex()
        }
    }

    @Test("DataProvider rejects non-HTTPS remote bases before fetching")
    func rejectsInsecureRemoteBase() async throws {
        let provider = DataProvider(baseURL: URL(string: "http://example.test/api/v1")!)
        await #expect(throws: DataProviderError.self) {
            _ = try await provider.fetchReleaseIndex()
        }
    }

    @Test("DataProvider response limits include their boundary")
    func responseSizeBoundary() throws {
        let url = URL(string: "https://macosdb.com/api/v1/macos/releases.json")!
        try DataProvider.validateResponseSize(16, limit: 16, url: url)
        #expect(throws: DataProviderError.self) {
            try DataProvider.validateResponseSize(17, limit: 16, url: url)
        }
    }

    @Test("DataProvider stops loading an oversized index")
    func rejectsOversizedIndexDuringLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-provider-size-\(UUID().uuidString)", isDirectory: true)
        let productRoot = root.appendingPathComponent("macos", isDirectory: true)
        try FileManager.default.createDirectory(at: productRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x20, count: 4 * 1_024 * 1_024 + 1)
            .write(to: productRoot.appendingPathComponent("releases.json"))

        let provider = DataProvider(baseURL: root)
        await #expect(throws: DataProviderError.self) {
            _ = try await provider.fetchReleaseIndex()
        }
    }

    @Test("DataProvider rejects duplicate index identities")
    func rejectsDuplicateIndexIdentities() async throws {
        let root = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("macos/releases.json")
        let data = try Data(contentsOf: indexURL)
        var entries = try JSONDecoder().decode([ReleaseIndexEntry].self, from: data)
        entries.append(try #require(entries.first))
        try writeJSON(entries, to: indexURL)

        let provider = DataProvider(baseURL: root)
        await #expect(throws: DataProviderError.self) {
            _ = try await provider.fetchReleaseIndex()
        }
    }

    @Test("DataProvider caches by the complete release identity")
    func cacheIncludesVersionAndBuild() async throws {
        let root = try makeLocalDataStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("macos/releases.json")
        var entries = try JSONDecoder().decode(
            [ReleaseIndexEntry].self,
            from: Data(contentsOf: indexURL)
        )
        let second = ReleaseIndexEntry(
            osVersion: "15.1",
            buildNumber: "24A335",
            releaseName: "Sequoia",
            releaseDate: "2024-10-28",
            dataFile: "releases/15/macOS-15.1-24A335.json"
        )
        entries.append(second)
        try writeJSON(entries, to: indexURL)
        try writeJSON(
            release(
                version: "15.1",
                build: "24A335",
                name: "Sequoia",
                date: "2024-10-28",
                componentVersion: "8.7.1"
            ),
            to: root.appendingPathComponent("macos/\(second.dataFile)")
        )

        let provider = DataProvider(baseURL: root)
        let index = try await provider.fetchReleaseIndex()
        let firstRelease = try await provider.fetchRelease(try #require(index.first))
        let secondRelease = try await provider.fetchRelease(try #require(index.last))

        #expect(firstRelease.osVersion == "15.0")
        #expect(secondRelease.osVersion == "15.1")
    }
}
