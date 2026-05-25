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

    @Test("validate with no arguments is rejected")
    func validateRequiresInput() throws {
        let result = try runMacosdb(["validate"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Provide at least one archive path or --dir"))
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

    /// Locate the built `macosdb` binary by walking up from the test source file
    /// to the package root, then searching the build output directories for the
    /// most recently built copy. Handles both `swift test` (binary lives under
    /// `.build/`) and `xcodebuild test` (under `DerivedData/Build/Products/`).
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
        let searchRoots = [".build", "DerivedData/Build/Products"]
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
