import ArgumentParser
import Darwin
import Foundation
import macOSdbCore

struct CleanupCommand: AsyncParsableCommand {
    private static let quarantineMarkerName = "io.linnane.macosdb.cleanup"
    private static let quarantineMarkerValue = Array("macosdb-cleanup-v1".utf8)

    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Find and remove leftover temp directories and mounted DMGs from aborted scans."
    )

    @Flag(name: .shortAndLong, help: "Actually unmount and delete (default is dry-run).")
    var force = false

    func run() async throws {
        let mounts = try findStaleMounts()
        let tempDirs = findStaleTempDirs()

        if mounts.isEmpty && tempDirs.isEmpty {
            printStatus("Nothing to clean up.")
            return
        }

        if !mounts.isEmpty {
            printStatus("Mounted DMGs from scans:")
            for mount in mounts {
                printStatus("  \(mount.mountPoint)  (\(mount.deviceNode))")
                printStatus("    source: \(mount.imagePath)")
            }
            printStatus("")
        }

        if !tempDirs.isEmpty {
            printStatus("Stale temp directories:")
            for dir in tempDirs {
                printStatus("  \(dir.path)")
            }
            printStatus("")
        }

        if !force {
            printStatus("Run with --force to clean up.")
            return
        }

        var unmountFailed = false
        for mount in mounts {
            switch try recheckStaleMount(mount) {
            case .stale:
                if !unmount(mount) { unmountFailed = true }
            case .ownedByRunningScan:
                printStatus("Skipped no-longer-stale mount \(mount.mountPoint)")
            case .unrecognizedWorkDir:
                printStatus("Skipped mount with unrecognized scan source \(mount.mountPoint)")
            }
        }

        guard !unmountFailed else { throw ExitCode.failure }

        var dirsToRemove: [URL] = []
        for dir in tempDirs {
            if Self.isStaleTempDir(dir) {
                dirsToRemove.append(dir)
            } else {
                printStatus("Skipped no-longer-stale directory \(dir.lastPathComponent)")
            }
        }
        guard removeDirectories(dirsToRemove) else { throw ExitCode.failure }
    }

    // MARK: - Stale mount detection

    struct StaleMount {
        let imagePath: String
        let mountPoint: String
        let deviceNode: String
    }

    private enum StaleMountRecheck {
        case stale
        case ownedByRunningScan
        case unrecognizedWorkDir
    }

    private func findStaleMounts() throws -> [StaleMount] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Drain the pipe before waiting: a large `hdiutil info` plist can exceed the
        // pipe buffer and deadlock if we wait for exit while hdiutil blocks on write.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let tempBase = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return try Self.staleMounts(from: data, tempBase: tempBase, terminationStatus: process.terminationStatus)
    }

    static func staleMounts(from data: Data, tempBase: String, terminationStatus: Int32 = 0) throws -> [StaleMount] {
        guard terminationStatus == 0 else {
            throw ValidationError("Could not inspect mounted disk images (hdiutil exited \(terminationStatus)).")
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw ValidationError("Could not inspect mounted disk images: unrecognized hdiutil output.")
        }

        var results: [StaleMount] = []
        for image in images {
            guard let imagePath = image["image-path"] as? String, !imagePath.isEmpty else {
                throw ValidationError("Could not inspect mounted disk images: missing image path.")
            }
            guard let workDir = scannerWorkDir(forImage: imagePath, tempBase: tempBase),
                  ScanWorkspace.ownershipState(workDir) == .stale else { continue }
            guard let entities = image["system-entities"] as? [[String: Any]] else {
                throw ValidationError("Could not inspect mounted disk images: missing scanner mount details.")
            }

            for entity in entities {
                guard entity["mount-point"] != nil else { continue }
                guard let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty,
                      let deviceNode = entity["dev-entry"] as? String, !deviceNode.isEmpty else {
                    throw ValidationError("Could not inspect mounted disk images: incomplete scanner mount identity.")
                }
                results.append(StaleMount(
                    imagePath: imagePath,
                    mountPoint: mountPoint,
                    deviceNode: deviceNode
                ))
            }
        }

        return results
    }

    /// The scanner work dir that contains an image, or nil if the source is outside
    /// the temporary directory or does not use a production scanner workspace name.
    static func scannerWorkDir(forImage imagePath: String, tempBase: String) -> URL? {
        let resolvedPath = normalizedTemporaryPath(imagePath)
        let resolvedBase = normalizedTemporaryPath(tempBase)
        let basePrefix = resolvedBase + "/"
        guard resolvedPath.hasPrefix(basePrefix) else { return nil }
        var dir = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent()
        while dir.path == resolvedBase || dir.path.hasPrefix(basePrefix) {
            if ScanWorkspace.isValidWorkspaceName(dir.lastPathComponent) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    private static func normalizedTemporaryPath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // Foundation can preserve /private for a missing leaf while spelling an
        // existing equivalent temporary directory as /var or /tmp.
        for privatePrefix in ["/private/var", "/private/tmp"]
            where resolved == privatePrefix || resolved.hasPrefix(privatePrefix + "/") {
            return String(resolved.dropFirst("/private".count))
        }
        return resolved
    }

    private func unmount(_ mount: StaleMount) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mount.deviceNode, "-force"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                printStatus("Unmounted \(mount.mountPoint)")
                return true
            }
            printStatus("Failed to unmount \(mount.mountPoint)")
        } catch {
            printStatus("Failed to unmount \(mount.mountPoint): \(error.localizedDescription)")
        }
        return false
    }

    private func recheckStaleMount(_ mount: StaleMount) throws -> StaleMountRecheck {
        let tempBase = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard let workDir = Self.scannerWorkDir(forImage: mount.imagePath, tempBase: tempBase) else {
            return .unrecognizedWorkDir
        }
        switch ScanWorkspace.ownershipState(workDir) {
        case .running:
            return .ownedByRunningScan
        case .stale:
            let stillMounted = try findStaleMounts().contains {
                $0.imagePath == mount.imagePath
                    && $0.mountPoint == mount.mountPoint
                    && $0.deviceNode == mount.deviceNode
            }
            return stillMounted ? .stale : .unrecognizedWorkDir
        case .unrecognized:
            return .unrecognizedWorkDir
        }
    }

    // MARK: - Stale temp directory detection

    private func findStaleTempDirs() -> [URL] {
        Self.staleTempDirs(in: FileManager.default.temporaryDirectory)
    }

    static func staleTempDirs(in tempDir: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        return contents.filter(Self.isStaleTempDir).sorted { $0.path < $1.path }
    }

    static func isStaleTempDir(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard ScanWorkspace.isValidWorkspaceName(name) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return false
        }
        let ownership = ScanWorkspace.ownershipState(url)
        if ownership == .stale {
            return true
        }
        return ownership == .unrecognized
            && ScanWorkspace.isValidCleanupQuarantineName(name)
            && hasCleanupQuarantineMarker(url)
    }

    // MARK: - Temp directory removal

    private func removeDirectories(_ urls: [URL]) -> Bool {
        var succeeded = true
        for url in urls {
            let quarantine = url.deletingLastPathComponent()
                .appendingPathComponent(".macosdb-cleanup-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: url, to: quarantine)
                guard Self.isStaleOwnedDirectory(quarantine) else {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try? FileManager.default.moveItem(at: quarantine, to: url)
                    }
                    printStatus("Skipped changed directory \(url.lastPathComponent)")
                    continue
                }
                try Self.markCleanupQuarantine(quarantine)
                try FileManager.default.removeItem(at: quarantine)
                printStatus("Removed \(url.lastPathComponent)")
            } catch {
                succeeded = false
                printStatus("Failed to remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return succeeded
    }

    private static func isStaleOwnedDirectory(_ url: URL) -> Bool {
        isStaleTempDir(url)
    }

    static func markCleanupQuarantine(_ url: URL) throws {
        let result = url.path.withCString { path in
            quarantineMarkerName.withCString { name in
                quarantineMarkerValue.withUnsafeBytes { marker in
                    setxattr(path, name, marker.baseAddress, marker.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func hasCleanupQuarantineMarker(_ url: URL) -> Bool {
        var value = [UInt8](repeating: 0, count: quarantineMarkerValue.count)
        let count = url.path.withCString { path in
            quarantineMarkerName.withCString { name in
                value.withUnsafeMutableBytes { marker in
                    getxattr(path, name, marker.baseAddress, marker.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        return count == quarantineMarkerValue.count && value == quarantineMarkerValue
    }

}
