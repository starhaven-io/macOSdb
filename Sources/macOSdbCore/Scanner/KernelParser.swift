import Foundation
import OSLog

enum KernelParser {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "KernelParser")

    /// Skip kernelcaches larger than this before reading them into memory. Real
    /// kernelcaches are tens of MB (the IM4P payload decompresses under
    /// `IM4PDecoder.maxDecompressedSize` = 128 MB); this only trips on a crafted
    /// archive trying to drive a single oversized whole-file read.
    static let maxKernelcacheBytes = 512 * 1_024 * 1_024 // 512 MB

    @concurrent
    static func parse(kernelcachePath: URL) async -> KernelInfo? {
        guard !Task.isCancelled else { return nil }
        let filename = kernelcachePath.lastPathComponent

        if let size = try? FileManager.default.attributesOfItem(
            atPath: kernelcachePath.path
        )[.size] as? Int, size > maxKernelcacheBytes {
            logger.warning("Skipping oversized kernelcache \(filename): \(size) bytes exceeds \(maxKernelcacheBytes)")
            return nil
        }

        guard let data = try? Data(contentsOf: kernelcachePath) else {
            logger.warning("Could not read kernelcache: \(filename)")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        logger.debug("Parsing kernelcache: \(filename) (\(data.count) bytes)")

        let kernelData: Data
        if IM4PDecoder.isIM4P(data) {
            logger.info("Kernelcache is IM4P-wrapped, decoding…")
            guard let decoded = IM4PDecoder.extractPayload(from: data) else {
                logger.warning("Failed to decode IM4P container for \(filename)")
                return nil
            }
            kernelData = decoded
        } else {
            kernelData = data
        }
        guard !Task.isCancelled else { return nil }

        let versions = scanVersions(in: kernelData)

        guard !versions.darwin.isEmpty else {
            logger.warning("No Darwin version found in \(filename)")
            return nil
        }

        let archSuffix = versions.archSuffix
        let arch = archSuffix.isEmpty ? "ARM64" : "ARM64_\(archSuffix)"
        let chip: String
        if let family = ChipFamily.from(archSuffix: archSuffix) {
            chip = family.displayName
        } else if !archSuffix.isEmpty {
            chip = archSuffix
        } else {
            chip = "Unknown"
        }

        let devices = parseDevicesFromFilename(filename)

        let kernelInfo = KernelInfo(
            file: filename,
            darwinVersion: versions.darwin,
            xnuVersion: versions.xnu,
            arch: arch,
            chip: chip,
            devices: devices
        )

        logger.info("Kernel: Darwin \(versions.darwin) / \(chip) / \(devices.count) devices")
        return kernelInfo
    }

    // MARK: - Version extraction

    struct KernelVersionStrings {
        var darwin = ""
        var xnu: String?
        var archSuffix = ""

        var isComplete: Bool { !darwin.isEmpty && xnu != nil && !archSuffix.isEmpty }
    }

    /// Single streaming pass over the kernel's printable strings, capturing the
    /// first match of each version field and stopping once all three are found —
    /// instead of materializing every string and scanning the array three times.
    static func scanVersions(in data: Data) -> KernelVersionStrings {
        let darwinRegex = /Darwin Kernel Version (\d+\.\d+\.\d+)/
        let xnuRegex = /xnu-(\d+\.\d+\.\d+(?:\.\d+)*)/
        let archRegex = /RELEASE_ARM64_([A-Za-z0-9]+)/

        var found = KernelVersionStrings()
        BinaryStringScanner.enumerateStrings(from: data) { string in
            if found.darwin.isEmpty, let match = string.firstMatch(of: darwinRegex) {
                found.darwin = String(match.1)
            }
            if found.xnu == nil, let match = string.firstMatch(of: xnuRegex) {
                found.xnu = String(match.1)
            }
            if found.archSuffix.isEmpty, let match = string.firstMatch(of: archRegex) {
                found.archSuffix = String(match.1)
            }
            return !found.isComplete // stop once every field is filled
        }
        return found
    }

    // MARK: - Device parsing

    /// Parse device model identifiers from a kernelcache filename.
    ///
    /// Examples:
    /// - `kernelcache.release.Mac16,1_2_3_10_12_13` → `["Mac16,1", "Mac16,2", ...]`
    /// - `kernelcache.release.MacBookAir10,1_MacBookPro17,1` → `["MacBookAir10,1", "MacBookPro17,1"]`
    /// - `kernelcache.release.VirtualMac2,1` → `["VirtualMac2,1"]`
    /// - `kernelcache.development.Mac16,1_2_3` → `["Mac16,1", "Mac16,2", "Mac16,3"]`
    /// - `kernelcache.release.mac13g` → `[]` (board codename, not device model IDs)
    static func parseDevicesFromFilename(_ filename: String) -> [String] {
        var suffix = filename
        for prefix in ["kernelcache.release.", "kernelcache.development."] {
            if let range = suffix.range(of: prefix) {
                suffix = String(suffix[range.upperBound...])
                break
            }
        }

        // Handle VirtualMac specially
        if suffix.hasPrefix("VirtualMac") {
            return [suffix]
        }

        let parts = suffix.split(separator: "_").map(String.init)
        var devices: [String] = []
        var currentPrefix = "" // e.g. "Mac16,"

        for part in parts {
            if part.first?.isLetter == true {
                if let commaIndex = part.lastIndex(of: ",") {
                    currentPrefix = String(part[...commaIndex])
                    devices.append(part)
                }
            } else if !currentPrefix.isEmpty {
                // Bare number — append to current prefix
                devices.append("\(currentPrefix)\(part)")
            }
        }

        return devices
    }
}
