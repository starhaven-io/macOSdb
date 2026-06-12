import Foundation
import OSLog

/// Uses `-nobrowse` and `-readonly` flags for headless read-only mounting.
actor DMGMounter {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "DMGMounter")

    struct MountPoint: Sendable {
        let path: String
        /// Device node (e.g. "/dev/disk4s1") for ejection.
        let deviceNode: String
    }

    func mount(dmgPath: URL) async throws -> MountPoint {
        Self.logger.info("Mounting DMG: \(dmgPath.path)")

        let result = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmgPath.path]
        )

        guard result.terminationStatus == 0 else {
            let errorMessage = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
            Self.logger.error("hdiutil attach failed: \(errorMessage)")
            throw ScannerError.dmgMountFailed(path: dmgPath.path, reason: errorMessage)
        }

        return try parseMountOutput(result.stdout, dmgPath: dmgPath.path)
    }

    func unmount(_ mountPoint: MountPoint) async {
        Self.logger.info("Unmounting: \(mountPoint.path)")

        do {
            let result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", mountPoint.deviceNode, "-force"],
                capturesStandardOutput: false,
                capturesStandardError: true
            )

            if result.terminationStatus != 0 {
                let errorMessage = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
                Self.logger.warning("hdiutil detach warning: \(errorMessage)")
            }
        } catch {
            Self.logger.warning("Failed to unmount \(mountPoint.path): \(error)")
        }
    }

    // MARK: - Private

    private func parseMountOutput(_ data: Data, dmgPath: String) throws -> MountPoint {
        let parsed: Any
        do {
            parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            Self.logger.error("Failed to parse hdiutil plist output: \(error.localizedDescription)")
            throw ScannerError.dmgMountFailed(path: dmgPath, reason: "Could not parse hdiutil plist output")
        }
        guard let plist = parsed as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            Self.logger.error("Unexpected hdiutil plist structure")
            throw ScannerError.dmgMountFailed(path: dmgPath, reason: "Unexpected hdiutil plist structure")
        }

        // Find the entity with a mount point (Apple_APFS or Apple_HFS volume)
        for entity in entities {
            if let mountPath = entity["mount-point"] as? String,
               let devEntry = entity["dev-entry"] as? String {
                Self.logger.info("Mounted at: \(mountPath) (\(devEntry))")
                return MountPoint(path: mountPath, deviceNode: devEntry)
            }
        }

        // Some DMGs have multiple partitions — look for any mount point
        // and find the corresponding device
        let deviceNode = entities.first?["dev-entry"] as? String ?? "/dev/unknown"
        for entity in entities {
            if let mountPath = entity["mount-point"] as? String {
                return MountPoint(path: mountPath, deviceNode: deviceNode)
            }
        }

        throw ScannerError.dmgMountFailed(
            path: dmgPath,
            reason: "No mount point found in hdiutil output"
        )
    }
}
