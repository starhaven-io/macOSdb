import Foundation
import OSLog

public enum KernelParser {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "KernelParser")

    @concurrent
    public static func parse(kernelcachePath: URL) async -> KernelInfo? {
        let filename = kernelcachePath.lastPathComponent

        guard let data = try? Data(contentsOf: kernelcachePath) else {
            logger.warning("Could not read kernelcache: \(filename)")
            return nil
        }

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

        let strings = BinaryStringScanner.extractStrings(from: kernelData)

        let darwinVersion = findDarwinVersion(in: strings)
        let xnuVersion = findXNUVersion(in: strings)
        let archSuffix = findArchSuffix(in: strings)

        guard !darwinVersion.isEmpty else {
            logger.warning("No Darwin version found in \(filename)")
            return nil
        }

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
            darwinVersion: darwinVersion,
            xnuVersion: xnuVersion,
            arch: arch,
            chip: chip,
            devices: devices
        )

        logger.info("Kernel: Darwin \(darwinVersion) / \(chip) / \(devices.count) devices")
        return kernelInfo
    }

    // MARK: - Version extraction

    private static func findDarwinVersion(in strings: [String]) -> String {
        let pattern = #"Darwin Kernel Version ([0-9]+\.[0-9]+\.[0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }

        for string in strings {
            let range = NSRange(string.startIndex..., in: string)
            if let match = regex.firstMatch(in: string, range: range),
               let captureRange = Range(match.range(at: 1), in: string) {
                return String(string[captureRange])
            }
        }
        return ""
    }

    private static func findXNUVersion(in strings: [String]) -> String? {
        let pattern = #"xnu-([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        for string in strings {
            let range = NSRange(string.startIndex..., in: string)
            if let match = regex.firstMatch(in: string, range: range),
               let captureRange = Range(match.range(at: 1), in: string) {
                return String(string[captureRange])
            }
        }
        return nil
    }

    private static func findArchSuffix(in strings: [String]) -> String {
        let pattern = #"RELEASE_ARM64_([A-Za-z0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }

        for string in strings {
            let range = NSRange(string.startIndex..., in: string)
            if let match = regex.firstMatch(in: string, range: range),
               let captureRange = Range(match.range(at: 1), in: string) {
                return String(string[captureRange])
            }
        }
        return ""
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
    public static func parseDevicesFromFilename(_ filename: String) -> [String] {
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
