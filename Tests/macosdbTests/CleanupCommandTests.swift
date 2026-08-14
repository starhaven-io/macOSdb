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

    @Test("Mount classification accepts only stale scanner-owned temp paths")
    func staleMountClassification() throws {
        let tempBase = try makeTempDir(prefix: "cleanup-base-")
        let staleDir = tempBase.appendingPathComponent("macosdb-stale", isDirectory: true)
        let activeDir = tempBase.appendingPathComponent("macosdb-active", isDirectory: true)
        let siblingBase = URL(fileURLWithPath: tempBase.path + "-sibling", isDirectory: true)
        let siblingDir = siblingBase.appendingPathComponent("macosdb-sibling", isDirectory: true)
        for directory in [staleDir, activeDir, siblingDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("\(getpid())".utf8).write(to: activeDir.appendingPathComponent("scan.pid"))
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: siblingBase)
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "images": [
                    image(path: staleDir.appendingPathComponent("System.dmg").path, device: "/dev/disk4s1"),
                    image(path: activeDir.appendingPathComponent("System.dmg").path, device: "/dev/disk5s1"),
                    image(path: siblingDir.appendingPathComponent("System.dmg").path, device: "/dev/disk6s1"),
                    ["image-path": staleDir.appendingPathComponent("NoEntities.dmg").path]
                ]
            ],
            format: .xml,
            options: 0
        )

        let mounts = CleanupCommand.staleMounts(from: data, tempBase: tempBase.path)

        #expect(mounts.count == 1)
        #expect(mounts.first?.deviceNode == "/dev/disk4s1")
        #expect(mounts.first?.mountPoint == "/Volumes/Test")
        #expect(
            CleanupCommand.scannerWorkDir(
                forImage: siblingDir.appendingPathComponent("System.dmg").path,
                tempBase: tempBase.path
            ) == nil
        )
    }

    @Test("Scanner path matching accepts the private temp-directory alias")
    func scannerPathPrivateAlias() {
        let workDir = CleanupCommand.scannerWorkDir(
            forImage: "/private/var/folders/macosdb-stale/System.dmg",
            tempBase: "/var/folders"
        )

        #expect(workDir?.path == "/var/folders/macosdb-stale")
    }

    @Test("Malformed hdiutil info output produces no stale mounts")
    func malformedMountOutputIsEmpty() {
        #expect(CleanupCommand.staleMounts(from: Data("invalid".utf8), tempBase: "/tmp").isEmpty)
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func image(path: String, device: String) -> [String: Any] {
        [
            "image-path": path,
            "system-entities": [[
                "mount-point": "/Volumes/Test",
                "dev-entry": device
            ]]
        ]
    }
}
