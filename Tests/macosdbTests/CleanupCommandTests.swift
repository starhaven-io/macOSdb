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
        let staleDir = try makeScannerTempDir()
        let activeDir = try makeScannerTempDir()
        let unmarkedDir = try makeScannerTempDir()
        let unrelatedDir = try makeTempDir(prefix: "other-test-")
        let notDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: staleDir)
            try? FileManager.default.removeItem(at: activeDir)
            try? FileManager.default.removeItem(at: unmarkedDir)
            try? FileManager.default.removeItem(at: unrelatedDir)
            try? FileManager.default.removeItem(at: notDirectory)
        }

        try Data("999999999".utf8).write(to: staleDir.appendingPathComponent("scan.pid"))
        try Data("\(getpid())".utf8).write(to: activeDir.appendingPathComponent("scan.pid"))
        try Data("not a directory".utf8).write(to: notDirectory)

        #expect(CleanupCommand.isStaleTempDir(staleDir) == true)
        #expect(CleanupCommand.isStaleTempDir(activeDir) == false)
        #expect(CleanupCommand.isStaleTempDir(unmarkedDir) == false)
        #expect(CleanupCommand.isStaleTempDir(unrelatedDir) == false)
        #expect(CleanupCommand.isStaleTempDir(notDirectory) == false)
    }

    @Test("Stale directory enumeration recovers hidden cleanup quarantines")
    func staleTempDirEnumerationIncludesQuarantines() throws {
        let tempBase = try makeTempDir(prefix: "cleanup-enumeration-base-")
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let scannerDir = tempBase.appendingPathComponent("macosdb-\(UUID().uuidString)")
        let quarantineDir = tempBase.appendingPathComponent(".macosdb-cleanup-\(UUID().uuidString)")
        let unrelatedHiddenDir = tempBase.appendingPathComponent(".unrelated-\(UUID().uuidString)")
        let unmarkedQuarantine = tempBase.appendingPathComponent(".macosdb-cleanup-\(UUID().uuidString)")
        let malformedQuarantine = tempBase.appendingPathComponent(".macosdb-cleanup-not-a-uuid")
        for directory in [scannerDir, quarantineDir, unrelatedHiddenDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("999999999".utf8).write(to: directory.appendingPathComponent("scan.pid"))
        }
        for directory in [unmarkedQuarantine, malformedQuarantine] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data("999999999".utf8).write(to: malformedQuarantine.appendingPathComponent("scan.pid"))
        let symlinkQuarantine = tempBase.appendingPathComponent(".macosdb-cleanup-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlinkQuarantine, withDestinationURL: scannerDir)

        let staleDirectories = CleanupCommand.staleTempDirs(in: tempBase)

        let expectedNames = [quarantineDir, scannerDir].map(\.lastPathComponent).sorted()
        #expect(staleDirectories.map(\.lastPathComponent) == expectedNames)
    }

    @Test("A cleanup quarantine remains recoverable after its scan marker is removed")
    func cleanupQuarantineMarkerSurvivesPartialRemoval() throws {
        let quarantine = try makeTempDir(prefix: ".macosdb-cleanup-")
        defer { try? FileManager.default.removeItem(at: quarantine) }
        let scanMarker = quarantine.appendingPathComponent("scan.pid")
        try Data("999999999".utf8).write(to: scanMarker)

        try CleanupCommand.markCleanupQuarantine(quarantine)
        try Data("\(getpid())".utf8).write(to: scanMarker)
        #expect(!CleanupCommand.isStaleTempDir(quarantine))
        try FileManager.default.removeItem(at: scanMarker)

        #expect(CleanupCommand.isStaleTempDir(quarantine))
    }

    @Test("Mount classification accepts only stale scanner-owned temp paths")
    func staleMountClassification() throws {
        let tempBase = try makeTempDir(prefix: "cleanup-base-")
        let staleDir = tempBase.appendingPathComponent("macosdb-\(UUID().uuidString)", isDirectory: true)
        let activeDir = tempBase.appendingPathComponent("macosdb-xcode-\(UUID().uuidString)", isDirectory: true)
        let siblingBase = URL(fileURLWithPath: tempBase.path + "-sibling", isDirectory: true)
        let siblingDir = siblingBase.appendingPathComponent("macosdb-sibling", isDirectory: true)
        for directory in [staleDir, activeDir, siblingDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("999999999".utf8).write(to: staleDir.appendingPathComponent("scan.pid"))
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
        let uuid = UUID().uuidString
        let workDir = CleanupCommand.scannerWorkDir(
            forImage: "/private/var/folders/macosdb-\(uuid)/System.dmg",
            tempBase: "/var/folders"
        )

        #expect(workDir?.path == "/var/folders/macosdb-\(uuid)")
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

    private func makeScannerTempDir() throws -> URL {
        try makeTempDir(prefix: "macosdb-")
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
