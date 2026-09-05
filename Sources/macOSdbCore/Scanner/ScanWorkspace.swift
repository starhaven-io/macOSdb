import Darwin
import Foundation

/// Conventions for a scanner work directory, shared between the scanner — which
/// marks its `macosdb-…` work dir as owned while a scan is in progress — and the
/// `cleanup` command, which uses that marker to avoid detaching mounts or deleting
/// a work directory belonging to a scan that is still running.
package enum ScanWorkspace {
    /// Name of the PID marker written into a scanner work directory.
    package static let pidFileName = "scan.pid"

    private static let markerPrefix = "macosdb-scan-v1:"
    private static let maxMarkerBytes = 128
    private static let cleanupQuarantinePrefix = ".macosdb-cleanup-"

    package enum OwnershipState: Equatable {
        case running
        case stale
        case unrecognized
    }

    package static func isValidWorkspaceName(_ name: String) -> Bool {
        if isValidCleanupQuarantineName(name) {
            return true
        }

        let uuid: String
        if name.hasPrefix("macosdb-xcode-") {
            uuid = String(name.dropFirst("macosdb-xcode-".count))
        } else if name.hasPrefix("macosdb-") {
            uuid = String(name.dropFirst("macosdb-".count))
        } else {
            return false
        }
        return UUID(uuidString: uuid)?.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
    }

    package static func isValidCleanupQuarantineName(_ name: String) -> Bool {
        guard name.hasPrefix(cleanupQuarantinePrefix) else { return false }
        let uuid = String(name.dropFirst(cleanupQuarantinePrefix.count))
        return UUID(uuidString: uuid)?.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
    }

    /// Records the current process as the owner of `workDir`. A scanner must not use
    /// a work directory unless this marker is created successfully: cleanup treats
    /// unmarked directories as unrelated and leaves them alone.
    package static func markOwned(_ workDir: URL) throws {
        let pidFile = workDir.appendingPathComponent(pidFileName)
        try Data("\(markerPrefix)\(getpid())\n".utf8).write(to: pidFile, options: .atomic)
    }

    /// Classifies a scanner work directory from its ownership marker. The numeric-only
    /// form remains readable so cleanup can safely handle workspaces left by older
    /// releases; missing or malformed markers are never considered scanner-owned.
    package static func ownershipState(_ workDir: URL) -> OwnershipState {
        let pidFile = workDir.appendingPathComponent(pidFileName)
        guard let raw = readMarker(pidFile) else {
            return .unrecognized
        }

        let marker = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pidText: String
        if marker.hasPrefix(markerPrefix) {
            pidText = String(marker.dropFirst(markerPrefix.count))
        } else {
            pidText = marker
        }

        guard !pidText.isEmpty,
              pidText.allSatisfy(\.isNumber),
              let pid = pid_t(pidText),
              pid > 0 else {
            return .unrecognized
        }

        return kill(pid, 0) == 0 || errno == EPERM ? .running : .stale
    }

    private static func readMarker(_ url: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= Int64(maxMarkerBytes) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size) + 1)
        let count = bytes.withUnsafeMutableBytes { buffer in
            read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard count > 0, count <= maxMarkerBytes else { return nil }
        return String(data: Data(bytes.prefix(count)), encoding: .utf8)
    }

    /// True if `workDir` holds a valid marker for a process that is still running.
    package static func isOwnedByRunningScan(_ workDir: URL) -> Bool {
        ownershipState(workDir) == .running
    }
}
