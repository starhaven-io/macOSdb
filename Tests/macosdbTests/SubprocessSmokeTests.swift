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

    @Test("validate preserves malformed sidecars unless rehash is explicit")
    func validateRejectsMalformedSidecar() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archive = tempDir.appendingPathComponent("fake.xip")
        let sidecar = archive.appendingPathExtension("sha256")
        try Data("contents".utf8).write(to: archive)
        try "not-a-checksum\n".write(to: sidecar, atomically: true, encoding: .utf8)

        let rejected = try runMacosdb(["validate", archive.path])
        #expect(rejected.exitCode != 0)
        #expect(rejected.stderr.contains("Invalid sidecar"))
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "not-a-checksum\n")

        let rehashed = try runMacosdb(["validate", archive.path, "--rehash"])
        #expect(rehashed.exitCode == 0)
        #expect(try String(contentsOf: sidecar, encoding: .utf8) != "not-a-checksum\n")
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

}

extension SubprocessSmokeTests {

    @Test("cleanup dry-run reports scanner temp directories without deleting them")
    func cleanupDryRunReportsStaleDirectory() throws {
        let staleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        try "macosdb-scan-v1:999999999\n".write(
            to: staleDirectory.appendingPathComponent("scan.pid"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: staleDirectory) }

        let result = try runMacosdb(["cleanup"])

        #expect(result.exitCode == 0)
        #expect(result.stderr.contains(staleDirectory.path))
        #expect(result.stderr.contains("Run with --force to clean up."))
        #expect(FileManager.default.fileExists(atPath: staleDirectory.path))
    }

    @Test("scan rejects a missing AEA key before opening the archive")
    func scanRejectsMissingAEAKey() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-scan-key-test-\(UUID().uuidString).ipsw")
        try Data("fixture".utf8).write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        let missingKey = archive.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString).pem")

        let result = try runMacosdb(["scan", archive.path, "--aea-key", missingKey.path])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("AEA key file not found"))
        #expect(result.stderr.contains(missingKey.path))
    }

    @Test("list renders its table and empty state")
    func listRendersPlainTextAndEmptyState() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let populated = try runMacosdb([
            "list", "--major", "15", "--data-url", dataRoot.path
        ])
        #expect(populated.exitCode == 0)
        #expect(populated.stdout.contains("Version     Build"))
        #expect(populated.stdout.contains("15.0        24A335"))
        #expect(populated.stdout.contains("15.1        24B2083"))

        let empty = try runMacosdb([
            "list", "--major", "99", "--data-url", dataRoot.path
        ])
        #expect(empty.exitCode == 0)
        #expect(empty.stdout.contains("No releases found."))
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

    @Test("show and compare resolve exact builds")
    func resolvesExactBuilds() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let slug = try runMacosdb([
            "show", "15.1-24B2083", "--json", "--data-url", dataRoot.path
        ])
        #expect(slug.exitCode == 0)
        #expect(try decodeJSONObject(slug.stdout)["buildNumber"] as? String == "24B2083")

        let flag = try runMacosdb([
            "show", "15.1", "--build", "24B2083", "--json", "--data-url", dataRoot.path
        ])
        #expect(flag.exitCode == 0)
        #expect(try decodeJSONObject(flag.stdout)["buildNumber"] as? String == "24B2083")

        let comparison = try runMacosdb([
            "compare", "15.1-24B83", "15.1-24B2083", "--json", "--data-url", dataRoot.path
        ])
        #expect(comparison.exitCode == 0)
        let comparisonJSON = try decodeJSONObject(comparison.stdout)
        #expect((comparisonJSON["from"] as? [String: Any])?["buildNumber"] as? String == "24B83")
        #expect((comparisonJSON["to"] as? [String: Any])?["buildNumber"] as? String == "24B2083")

        let missing = try runMacosdb([
            "show", "15.1", "--build", "24B9999", "--json", "--data-url", dataRoot.path
        ])
        #expect(missing.exitCode != 0)
        #expect(missing.stderr.contains("24B9999"))
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

        let slug = try runMacosdb([
            "show", "15.0", "--component", "libbz2", "--json", "--data-url", dataRoot.path
        ])
        #expect(slug.exitCode == 0)
        let slugComponents = try requireArray(try decodeJSONObject(slug.stdout)["components"])
        #expect(slugComponents.count == 1)
        #expect(slugComponents.first?["name"] as? String == "libbz2 (bzip2)")
    }

    @Test("show renders release, SDK, kernel, and component details")
    func showRendersDetailedPlainText() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let result = try runMacosdb([
            "show", "15.0", "--detailed", "--data-url", dataRoot.path
        ])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("macOS 15.0 Sequoia (24A335)"))
        #expect(result.stdout.contains("Released: 2025-01-01"))
        #expect(result.stdout.contains("IPSW: https://example.com/macOS-15.0.ipsw"))
        #expect(result.stdout.contains("SDK 15.0 (24A335)"))
        #expect(result.stdout.contains("M4 — Darwin 24.0.0 / XNU 11215.1.10"))
        #expect(result.stdout.contains("Devices: Mac16,1"))
        #expect(result.stdout.contains("Supported chips: M4"))
        #expect(result.stdout.contains("Component"))
        #expect(result.stdout.contains("httpd"))
    }

    @Test("show supports substring filters and an empty result")
    func showRendersFilteredAndEmptyComponents() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let filtered = try runMacosdb([
            "show", "15.0", "--component", "bz2", "--data-url", dataRoot.path
        ])
        #expect(filtered.exitCode == 0)
        #expect(filtered.stdout.contains("libbz2 (bzip2)"))
        #expect(filtered.stdout.contains("libbz2-extra"))
        #expect(!filtered.stdout.contains("httpd"))

        let empty = try runMacosdb([
            "show", "15.0", "--component", "missing", "--data-url", dataRoot.path
        ])
        #expect(empty.exitCode == 0)
        #expect(empty.stdout.contains("No components found."))
    }

    @Test("show identifies a device-specific release")
    func showRendersDeviceSpecificMetadata() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let result = try runMacosdb([
            "show", "15.1-24B2083", "--data-url", dataRoot.path
        ])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("Type: Device-specific build"))
    }

    @Test("compare labels same-version builds by build number")
    func compareLabelsSameVersionByBuild() throws {
        let dataRoot = try LocalDataStore.make()
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let sameVersion = try runMacosdb([
            "compare", "15.1-24B83", "15.1-24B2083", "--data-url", dataRoot.path
        ])
        #expect(sameVersion.exitCode == 0)
        #expect(sameVersion.stdout.contains("(24B83)"))
        #expect(sameVersion.stdout.contains("(24B2083)"))
        // Columns fall back to builds so the two sides stay distinguishable.
        #expect(sameVersion.stdout.contains("24B83               24B2083"))

        let acrossVersions = try runMacosdb([
            "compare", "15.0", "15.1", "--data-url", dataRoot.path
        ])
        #expect(acrossVersions.exitCode == 0)
        #expect(acrossVersions.stdout.contains("15.0                15.1"))
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
