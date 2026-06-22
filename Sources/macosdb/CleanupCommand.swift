import ArgumentParser
import Foundation
import macOSdbCore

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Find and remove leftover temp directories and mounted DMGs from aborted scans."
    )

    @Flag(name: .shortAndLong, help: "Actually unmount and delete (default is dry-run).")
    var force = false

    func run() async throws {
        let mounts = findStaleMounts()
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

        for mount in mounts {
            unmount(mount)
        }

        removeDirectories(tempDirs)
    }

    // MARK: - Stale mount detection

    private struct StaleMount {
        let imagePath: String
        let mountPoint: String
        let deviceNode: String
    }

    private func findStaleMounts() -> [StaleMount] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        // Drain the pipe before waiting: a large `hdiutil info` plist can exceed the
        // pipe buffer and deadlock if we wait for exit while hdiutil blocks on write.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return [] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            return []
        }

        let tempBase = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path

        var results: [StaleMount] = []
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  let workDir = scannerWorkDir(forImage: imagePath, tempBase: tempBase),
                  let entities = image["system-entities"] as? [[String: Any]] else {
                continue
            }

            // Leave volumes mounted by a scan that is still running.
            if ScanWorkspace.isOwnedByRunningScan(workDir) { continue }

            for entity in entities {
                guard let mountPoint = entity["mount-point"] as? String,
                      let deviceNode = entity["dev-entry"] as? String else {
                    continue
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

    /// The `macosdb-…` work dir that contains a scanner-created image, or nil if the
    /// image isn't one of ours — so `--force` only ever detaches volumes from the
    /// scanner's own work dirs under the temp dir, never unrelated user volumes.
    private func scannerWorkDir(forImage imagePath: String, tempBase: String) -> URL? {
        let resolved = URL(fileURLWithPath: imagePath).resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(tempBase) else { return nil }
        var dir = resolved.deletingLastPathComponent()
        while dir.path.hasPrefix(tempBase) {
            if dir.lastPathComponent.hasPrefix("macosdb-") { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    private func unmount(_ mount: StaleMount) {
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
            } else {
                printStatus("Failed to unmount \(mount.mountPoint)")
            }
        } catch {
            printStatus("Failed to unmount \(mount.mountPoint): \(error.localizedDescription)")
        }
    }

    // MARK: - Stale temp directory detection

    private func findStaleTempDirs() -> [URL] {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("macosdb-") else { return false }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false else { return false }
            // Don't delete a work dir whose scan is still running.
            return !ScanWorkspace.isOwnedByRunningScan(url)
        }.sorted { $0.path < $1.path }
    }

    // MARK: - Temp directory removal

    private func removeDirectories(_ urls: [URL]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/rm")
        process.arguments = ["-rf"] + urls.map(\.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        var frame = 0

        do {
            try process.run()
        } catch {
            printStatus("Failed to remove directories: \(error.localizedDescription)")
            return
        }

        while process.isRunning {
            printInline("\(spinner[frame % spinner.count]) Removing \(urls.count) directory(s)...")
            frame += 1
            Thread.sleep(forTimeInterval: 0.1)
        }

        printInline("")
        if process.terminationStatus == 0 {
            for url in urls {
                printStatus("Removed \(url.lastPathComponent)")
            }
        } else {
            printStatus("Failed to remove directories")
        }
    }

}
