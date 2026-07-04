import Foundation
import Testing

@testable import macosdb

@Suite("CleanupCommand parsing and stale detection")
struct CleanupCommandTests {

    @Test("Parses with dry-run defaults")
    func parsesDefaults() throws {
        let cmd = try CleanupCommand.parse([])

        #expect(cmd.force == false)
    }

    @Test("Parses force flag")
    func parsesForce() throws {
        let cmd = try CleanupCommand.parse(["--force"])

        #expect(cmd.force == true)
    }

    @Test("Stale temp dir detection ignores active scan markers")
    func staleTempDirDetection() throws {
        let staleDir = try makeTempDir(prefix: "macosdb-test-")
        let activeDir = try makeTempDir(prefix: "macosdb-test-")
        let unrelatedDir = try makeTempDir(prefix: "other-test-")
        let notDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: staleDir)
            try? FileManager.default.removeItem(at: activeDir)
            try? FileManager.default.removeItem(at: unrelatedDir)
            try? FileManager.default.removeItem(at: notDirectory)
        }

        try Data("\(getpid())".utf8).write(to: activeDir.appendingPathComponent("scan.pid"))
        try Data("not a directory".utf8).write(to: notDirectory)

        #expect(CleanupCommand.isStaleTempDir(staleDir) == true)
        #expect(CleanupCommand.isStaleTempDir(activeDir) == false)
        #expect(CleanupCommand.isStaleTempDir(unrelatedDir) == false)
        #expect(CleanupCommand.isStaleTempDir(notDirectory) == false)
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
