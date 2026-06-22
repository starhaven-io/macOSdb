import Foundation
import Testing

@testable import macOSdbCore

/// `cleanup` relies on these to tell an aborted scan's leftovers from a scan that
/// is still running, so it never deletes or unmounts an in-progress scan.
@Suite("Scan workspace ownership")
struct ScanWorkspaceTests {

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("An unmarked work dir is not owned by a running scan")
    func unmarkedIsNotOwned() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ScanWorkspace.isOwnedByRunningScan(dir) == false)
    }

    @Test("A dir marked by this (live) process reads as owned")
    func markedByLiveProcessIsOwned() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        ScanWorkspace.markOwned(dir)
        #expect(ScanWorkspace.isOwnedByRunningScan(dir) == true)
    }

    @Test("A marker for a dead PID does not count as a running scan")
    func deadPIDIsNotOwned() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Above the macOS max PID, so guaranteed not to be a live process.
        try Data("999999999".utf8).write(to: dir.appendingPathComponent(ScanWorkspace.pidFileName))
        #expect(ScanWorkspace.isOwnedByRunningScan(dir) == false)
    }

    @Test("A non-numeric marker is ignored")
    func garbageMarkerIsNotOwned() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not-a-pid".utf8).write(to: dir.appendingPathComponent(ScanWorkspace.pidFileName))
        #expect(ScanWorkspace.isOwnedByRunningScan(dir) == false)
    }
}
