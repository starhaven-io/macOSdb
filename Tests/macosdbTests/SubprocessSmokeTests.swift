import Foundation
import Testing

@Suite("macosdb subprocess smoke tests")
struct SubprocessSmokeTests {

    @Test("--help exits zero and lists subcommands")
    func helpListsSubcommands() throws {
        let result = try runMacosdb(["--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("scan"))
        #expect(result.stdout.contains("list"))
        #expect(result.stdout.contains("show"))
        #expect(result.stdout.contains("compare"))
        #expect(result.stdout.contains("validate"))
    }

    @Test("scan with missing archive exits non-zero")
    func scanMissingArchiveExitsNonZero() throws {
        let missing = NSTemporaryDirectory() + "definitely-not-here-\(UUID().uuidString).ipsw"
        let result = try runMacosdb(["scan", missing])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Archive not found") || result.stdout.contains("Archive not found"))
    }

    @Test("scan --update-index without --release-date is rejected")
    func scanUpdateIndexRequiresReleaseDate() throws {
        let result = try runMacosdb(["scan", "archive.ipsw", "--update-index"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("--release-date"))
    }

    @Test("scan rejects a malformed --release-date")
    func scanRejectsMalformedDate() throws {
        let result = try runMacosdb(["scan", "archive.ipsw", "--update-index", "--release-date", "garbage"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("ISO 8601") || result.stderr.contains("release-date"))
    }

    @Test("validate with no arguments is rejected")
    func validateRequiresInput() throws {
        let result = try runMacosdb(["validate"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Provide at least one archive path or --dir"))
    }

    @Test("validate copies source mtime onto the .sha256 sidecar")
    func validateSyncsSidecarMtime() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-mtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archive = tempDir.appendingPathComponent("fake.xip")
        try Data("not a real xip".utf8).write(to: archive)

        // Pick a fixed mtime well in the past so the test doesn't accidentally
        // match a wall-clock-near write time.
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: expected],
            ofItemAtPath: archive.path
        )

        let result = try runMacosdb(["validate", archive.path])
        #expect(result.exitCode == 0)

        let sidecar = archive.appendingPathExtension("sha256")
        let sidecarMtime = try FileManager.default
            .attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date
        #expect(sidecarMtime == expected)
    }

    @Test("validate verifies an existing sidecar and detects a mismatch")
    func validateVerifiesAndDetectsMismatch() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archive = tempDir.appendingPathComponent("fake.xip")
        try Data("original contents".utf8).write(to: archive)

        // First run creates the sidecar.
        let created = try runMacosdb(["validate", archive.path])
        #expect(created.exitCode == 0)
        #expect(created.stderr.contains("sha256:"))

        // Second run recomputes and verifies against the stored hash.
        let verified = try runMacosdb(["validate", archive.path])
        #expect(verified.exitCode == 0)
        #expect(verified.stderr.contains("verified"))

        // Tampering with the archive must be detected as a mismatch (non-zero exit).
        try Data("tampered contents".utf8).write(to: archive)
        let mismatch = try runMacosdb(["validate", archive.path])
        #expect(mismatch.exitCode != 0)
        #expect(mismatch.stderr.contains("MISMATCH"))

        // --rehash overwrites the stale sidecar and succeeds again.
        let rehashed = try runMacosdb(["validate", archive.path, "--rehash"])
        #expect(rehashed.exitCode == 0)
        #expect(rehashed.stderr.contains("sha256:"))
    }

    @Test("list --json sorts same-version builds numerically")
    func listSortsBuildNumbersNumerically() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let result = try runMacosdb([
            "list", "--major", "15", "--json", "--data-url", dataRoot.path
        ])

        #expect(result.exitCode == 0)
        let entries = try decodeJSONArray(result.stdout)
        let buildNumbers = entries
            .filter { $0["osVersion"] as? String == "15.1" }
            .compactMap { $0["buildNumber"] as? String }
        #expect(buildNumbers == ["24B83", "24B2083"])
    }

    @Test("compare --changed --json filters unchanged components")
    func compareChangedJSONFiltersUnchangedComponents() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let result = try runMacosdb([
            "compare", "14.0", "15.0", "--changed", "--json", "--data-url", dataRoot.path
        ])

        #expect(result.exitCode == 0)
        let object = try decodeJSONObject(result.stdout)
        let changes = try requireArray(object["changes"])
        let names = changes.compactMap { $0["name"] as? String }
        #expect(names == ["httpd"])

        let added = try requireArray(object["addedComponents"])
        #expect(added.compactMap { $0["name"] as? String } == ["newtool"])
    }

    @Test("compare --json keeps unchanged common components")
    func compareJSONKeepsUnchangedComponents() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let result = try runMacosdb([
            "compare", "14.0", "15.0", "--json", "--data-url", dataRoot.path
        ])

        #expect(result.exitCode == 0)
        let object = try decodeJSONObject(result.stdout)
        let changes = try requireArray(object["changes"])
        let curl = changes.first { $0["name"] as? String == "curl" }
        #expect(curl?["direction"] as? String == "unchanged")
    }

    @Test("show --component --json keeps the release schema")
    func showComponentJSONKeepsReleaseSchema() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let result = try runMacosdb([
            "show", "15.0", "--component", "curl", "--json", "--data-url", dataRoot.path
        ])

        #expect(result.exitCode == 0)
        let object = try decodeJSONObject(result.stdout)
        let components = try requireArray(object["components"])
        #expect(object["buildNumber"] as? String == "24A335")
        #expect(components.count == 1)
        #expect(components.first?["name"] as? String == "curl")
    }

    @Test("show --json prefers the universal build for a duplicate version")
    func showJSONPrefersUniversalRelease() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let result = try runMacosdb([
            "show", "15.1", "--json", "--data-url", dataRoot.path
        ])

        #expect(result.exitCode == 0)
        let object = try decodeJSONObject(result.stdout)
        #expect(object["buildNumber"] as? String == "24B83")
    }

    // MARK: - Helpers

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runMacosdb(_ arguments: [String], file: String = #filePath) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try Self.findBinary(testSourcePath: file)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private enum TestDataError: Error {
        case invalidJSONShape
    }

    private func decodeJSONArray(_ string: String) throws -> [[String: Any]] {
        let data = Data(string.utf8)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TestDataError.invalidJSONShape
        }
        return array
    }

    private func decodeJSONObject(_ string: String) throws -> [String: Any] {
        let data = Data(string.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestDataError.invalidJSONShape
        }
        return object
    }

    private func requireArray(_ value: Any?) throws -> [[String: Any]] {
        guard let array = value as? [[String: Any]] else {
            throw TestDataError.invalidJSONShape
        }
        return array
    }

    /// Locate the built `macosdb` binary by walking up from the test source file
    /// to the package root, then searching the build output directories for the
    /// most recently built copy under `.build/`.
    /// Swift Testing's runner loads the .xctest dynamically, so `Bundle.allBundles`
    /// doesn't reliably contain it the way it does under XCTest.
    private static func findBinary(testSourcePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: testSourcePath).deletingLastPathComponent()
        while dir.path != "/" {
            let packageSwift = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return try locateBinary(under: dir)
            }
            dir.deleteLastPathComponent()
        }
        fatalError("Could not find Package.swift walking up from \(testSourcePath)")
    }

    private static func locateBinary(under packageRoot: URL) throws -> URL {
        let searchRoots = [".build"]
            .map { packageRoot.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        let candidates = searchRoots.flatMap { root -> [URL] in
            let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
            return subpaths
                .filter { $0.hasSuffix("/macosdb") || $0 == "macosdb" }
                .map { root.appendingPathComponent($0) }
                .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        }

        guard let binary = candidates.max(by: { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }) else {
            fatalError("Could not find a built macosdb binary under \(packageRoot.path) — build the package first")
        }
        return binary
    }
}

private enum LocalDataStore {
    static func make() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-cli-data-\(UUID().uuidString)", isDirectory: true)
        let macosDir = root.appendingPathComponent("macos", isDirectory: true)
        let releases14 = macosDir.appendingPathComponent("releases/14", isDirectory: true)
        let releases15 = macosDir.appendingPathComponent("releases/15", isDirectory: true)
        try FileManager.default.createDirectory(at: releases14, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: releases15, withIntermediateDirectories: true)

        try writeIndex(to: macosDir)
        try writeReleases(releases14: releases14, releases15: releases15)
        return root
    }

    private static func writeIndex(to macosDir: URL) throws {
        try writeJSONObject([
            indexEntry(
                version: "14.0",
                build: "23A344",
                releaseName: "Sonoma",
                dataFile: "releases/14/macOS-14.0-23A344.json"
            ),
            indexEntry(
                version: "15.0",
                build: "24A335",
                releaseName: "Sequoia",
                dataFile: "releases/15/macOS-15.0-24A335.json"
            ),
            indexEntry(
                version: "15.1",
                build: "24B2083",
                releaseName: "Sequoia",
                dataFile: "releases/15/macOS-15.1-24B2083.json",
                isDeviceSpecific: true
            ),
            indexEntry(
                version: "15.1",
                build: "24B83",
                releaseName: "Sequoia",
                dataFile: "releases/15/macOS-15.1-24B83.json"
            )
        ], to: macosDir.appendingPathComponent("releases.json"))
    }

    private static func writeReleases(releases14: URL, releases15: URL) throws {
        try writeJSONObject(
            release(
                version: "14.0",
                build: "23A344",
                releaseName: "Sonoma",
                components: [
                    component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                    component(name: "httpd", version: "2.4.59", path: "/usr/sbin/httpd")
                ]
            ),
            to: releases14.appendingPathComponent("macOS-14.0-23A344.json")
        )
        try writeJSONObject(
            release(
                version: "15.0",
                build: "24A335",
                releaseName: "Sequoia",
                components: [
                    component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                    component(name: "httpd", version: "2.4.62", path: "/usr/sbin/httpd"),
                    component(name: "newtool", version: "1.0", path: "/usr/bin/newtool")
                ]
            ),
            to: releases15.appendingPathComponent("macOS-15.0-24A335.json")
        )
        try writeJSONObject(
            release(
                version: "15.1",
                build: "24B83",
                releaseName: "Sequoia",
                components: [
                    component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
                ]
            ),
            to: releases15.appendingPathComponent("macOS-15.1-24B83.json")
        )
    }

    private static func indexEntry(
        version: String,
        build: String,
        releaseName: String,
        dataFile: String,
        isDeviceSpecific: Bool = false
    ) -> [String: Any] {
        [
            "osVersion": version,
            "buildNumber": build,
            "releaseName": releaseName,
            "releaseDate": "2025-01-01",
            "isBeta": false,
            "isRC": false,
            "isDeviceSpecific": isDeviceSpecific,
            "dataFile": dataFile
        ]
    }

    private static func release(
        version: String,
        build: String,
        releaseName: String,
        components: [[String: Any]]
    ) -> [String: Any] {
        [
            "osVersion": version,
            "buildNumber": build,
            "releaseName": releaseName,
            "releaseDate": "2025-01-01",
            "isBeta": false,
            "isRC": false,
            "isDeviceSpecific": false,
            "kernels": [],
            "components": components
        ]
    }

    private static func component(name: String, version: String, path: String) -> [String: Any] {
        [
            "name": name,
            "version": version,
            "path": path,
            "source": "filesystem"
        ]
    }

    private static func writeJSONObject(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
