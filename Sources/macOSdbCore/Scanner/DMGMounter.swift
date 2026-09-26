import Foundation
import OSLog

/// Uses `-nobrowse` and `-readonly` flags for headless read-only mounting.
actor DMGMounter {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "DMGMounter")

    /// Generous ceilings — mounting a local image is normally a few seconds, so
    /// these only fire if `hdiutil` wedges.
    private static let attachTimeout: TimeInterval = 300
    private static let detachTimeout: TimeInterval = 120
    private static let infoTimeout: TimeInterval = 60

    typealias HdiutilRunner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) async throws -> ProcessRunResult

    struct MountPoint: Sendable {
        let path: String
        /// Device node (e.g. "/dev/disk4s1") for ejection.
        let deviceNode: String
    }

    /// Devices, or image paths when the device is unknown, that may still be attached.
    private(set) var unreleasedImages: [String] = []
    private let runHdiutil: HdiutilRunner

    /// Every `hdiutil` call runs to completion after cancellation: an interrupted
    /// attach can still attach its image, and teardown must always get to detach it.
    init(runHdiutil: @escaping HdiutilRunner = { arguments, timeout in
        try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: arguments,
            timeout: timeout,
            respectsCancellation: false
        )
    }) {
        self.runHdiutil = runHdiutil
    }

    func mount(dmgPath: URL) async throws -> MountPoint {
        Self.logger.info("Mounting DMG: \(dmgPath.path)")

        let mountPoint: MountPoint
        do {
            let result = try await runHdiutil(["attach", "-nobrowse", "-readonly", "-plist", dmgPath.path], Self.attachTimeout)
            guard result.terminationStatus == 0 else {
                let errorMessage = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
                Self.logger.error("hdiutil attach failed: \(errorMessage)")
                throw ScannerError.dmgMountFailed(path: dmgPath.path, reason: errorMessage)
            }
            mountPoint = try parseMountOutput(result.stdout, dmgPath: dmgPath.path)
        } catch {
            // A timed-out, failed, or unparsed attach can still leave the image attached.
            await detachImages(backedBy: dmgPath)
            throw error
        }

        if Task.isCancelled {
            await unmount(mountPoint)
            throw CancellationError()
        }
        return mountPoint
    }

    func unmount(_ mountPoint: MountPoint) async {
        Self.logger.info("Unmounting: \(mountPoint.path)")
        await detach(mountPoint.deviceNode)
    }

    private func detach(_ device: String) async {
        do {
            let result = try await runHdiutil(["detach", device, "-force"], Self.detachTimeout)
            if result.terminationStatus == 0 { return }
            let errorMessage = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
            Self.logger.error("hdiutil detach \(device) failed: \(errorMessage)")
        } catch {
            Self.logger.error("Failed to detach \(device): \(error)")
        }
        unreleasedImages.append(device)
    }

    private func detachImages(backedBy dmgPath: URL) async {
        var source = stat()
        guard stat(dmgPath.path, &source) == 0 else {
            unreleasedImages.append(dmgPath.path)
            return
        }
        let devices: [String]
        do {
            let result = try await runHdiutil(["info", "-plist"], Self.infoTimeout)
            guard result.terminationStatus == 0 else {
                throw ScannerError.dmgMountFailed(path: dmgPath.path, reason: "hdiutil info failed")
            }
            devices = try Self.imageDevices(inInfo: result.stdout, backedBy: source, dmgPath: dmgPath.path)
        } catch {
            Self.logger.error("Could not find images attached from \(dmgPath.path): \(error)")
            unreleasedImages.append(dmgPath.path)
            return
        }
        for device in devices {
            await detach(device)
        }
    }

    /// The whole-disk device of each attached image whose backing file is `source`.
    static func imageDevices(inInfo data: Data, backedBy source: stat, dmgPath: String) throws -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw ScannerError.dmgMountFailed(path: dmgPath, reason: "Unexpected hdiutil info structure")
        }
        return try images.compactMap { image in
            var candidate = stat()
            guard let imagePath = image["image-path"] as? String,
                  stat(imagePath, &candidate) == 0,
                  candidate.st_dev == source.st_dev,
                  candidate.st_ino == source.st_ino else {
                return nil
            }
            guard let entities = image["system-entities"] as? [[String: Any]],
                  let device = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }),
                  !device.isEmpty else {
                throw ScannerError.dmgMountFailed(path: dmgPath, reason: "Missing attached image device identity")
            }
            return device
        }
    }

    // MARK: - Private

    func parseMountOutput(_ data: Data, dmgPath: String) throws -> MountPoint {
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
