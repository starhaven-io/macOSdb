import Foundation

/// Conventions for a scanner work directory, shared between the scanner — which
/// marks its `macosdb-…` work dir as owned while a scan is in progress — and the
/// `cleanup` command, which uses that marker to avoid detaching mounts or deleting
/// a work directory belonging to a scan that is still running.
public enum ScanWorkspace {
    /// Name of the PID marker written into a scanner work directory.
    public static let pidFileName = "scan.pid"

    /// Records the current process as the owner of `workDir` (best effort). The file
    /// is removed along with the work dir when the scan finishes or is cleaned up.
    public static func markOwned(_ workDir: URL) {
        let pidFile = workDir.appendingPathComponent(pidFileName)
        try? Data("\(getpid())".utf8).write(to: pidFile)
    }

    /// True if `workDir` holds a PID marker for a process that is still running, in
    /// which case `cleanup` must leave it (and its mounts) alone. A missing or
    /// unparsable marker, or a dead PID, reads as not-running.
    public static func isOwnedByRunningScan(_ workDir: URL) -> Bool {
        let pidFile = workDir.appendingPathComponent(pidFileName)
        guard let raw = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        // kill(pid, 0) probes a process without signaling it: success or EPERM means
        // it exists; ESRCH means it's gone.
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
