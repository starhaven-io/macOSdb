import Darwin
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
        #expect(ScanWorkspace.ownershipState(dir) == .unrecognized)
    }

    @Test("A dir marked by this (live) process reads as owned")
    func markedByLiveProcessIsOwned() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ScanWorkspace.markOwned(dir)
        #expect(ScanWorkspace.isOwnedByRunningScan(dir) == true)
        #expect(ScanWorkspace.ownershipState(dir) == .running)
    }

    @Test("A marker for a dead PID does not count as a running scan")
    func deadPIDIsNotOwned() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Above the macOS max PID, so guaranteed not to be a live process.
        try Data("999999999".utf8).write(to: dir.appendingPathComponent(ScanWorkspace.pidFileName))
        #expect(ScanWorkspace.isOwnedByRunningScan(dir) == false)
        #expect(ScanWorkspace.ownershipState(dir) == .stale)
    }

    @Test("A non-numeric marker is ignored")
    func garbageMarkerIsNotOwned() throws {
        let dir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not-a-pid".utf8).write(to: dir.appendingPathComponent(ScanWorkspace.pidFileName))
        #expect(ScanWorkspace.isOwnedByRunningScan(dir) == false)
        #expect(ScanWorkspace.ownershipState(dir) == .unrecognized)
    }

    @Test("Only production scanner workspace names are accepted")
    func workspaceNameValidation() {
        let uuid = UUID().uuidString
        #expect(ScanWorkspace.isValidWorkspaceName("macosdb-\(uuid)"))
        #expect(ScanWorkspace.isValidWorkspaceName("macosdb-xcode-\(uuid)"))
        #expect(ScanWorkspace.isValidWorkspaceName(".macosdb-cleanup-\(uuid)"))
        #expect(!ScanWorkspace.isValidWorkspaceName("macosdb-test-\(uuid)"))
        #expect(!ScanWorkspace.isValidWorkspaceName(".macosdb-cleanup-not-a-uuid"))
        #expect(!ScanWorkspace.isValidWorkspaceName("macosdb-"))
    }

    @Test("Marker symlinks, FIFOs, oversized files, and invalid PIDs are unrecognized")
    func rejectsSpecialAndMalformedMarkers() throws {
        for marker in ["0", "-1", String(repeating: "1", count: 129)] {
            let dir = try makeWorkDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data(marker.utf8).write(to: dir.appendingPathComponent(ScanWorkspace.pidFileName))
            #expect(ScanWorkspace.ownershipState(dir) == .unrecognized)
        }

        let symlinkDir = try makeWorkDir()
        let target = symlinkDir.appendingPathComponent("outside-marker")
        try Data("\(getpid())".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: symlinkDir.appendingPathComponent(ScanWorkspace.pidFileName),
            withDestinationURL: target
        )
        defer { try? FileManager.default.removeItem(at: symlinkDir) }
        #expect(ScanWorkspace.ownershipState(symlinkDir) == .unrecognized)

        let fifoDir = try makeWorkDir()
        let fifo = fifoDir.appendingPathComponent(ScanWorkspace.pidFileName)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(at: fifoDir) }
        #expect(ScanWorkspace.ownershipState(fifoDir) == .unrecognized)
    }
}
