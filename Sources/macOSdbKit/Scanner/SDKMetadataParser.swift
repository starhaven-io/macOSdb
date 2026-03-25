import Foundation
import OSLog

/// Shared utilities for parsing SDK metadata from SDKSettings.json files.
enum SDKMetadataParser {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "SDKMetadataParser")

    /// Parse a single SDKSettings.json file into an SDKInfo.
    static func parseSDKSettingsJSON(at path: URL) -> SDKInfo? {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let version = json["Version"] as? String else {
            return nil
        }

        logger.debug("macOS SDK \(version)")

        return SDKInfo(sdkVersion: version)
    }

    /// Find and parse all macOS SDKSettings.json files under a directory.
    /// Returns deduplicated SDKInfo sorted by version descending.
    static func findMacOSSDKs(in directory: URL) -> [SDKInfo] {
        let fileManager = FileManager.default
        var sdks: [SDKInfo] = []

        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "SDKSettings.json",
                   fileURL.path.contains("MacOSX"),
                   let sdk = parseSDKSettingsJSON(at: fileURL) {
                    sdks.append(sdk)
                }
            }
        }

        // Deduplicate by SDK version
        let uniqueSDKs = Dictionary(grouping: sdks, by: \.sdkVersion)
            .values.compactMap(\.first)
            .sorted { $0.sdkVersion > $1.sdkVersion }

        logger.info("Found \(uniqueSDKs.count) macOS SDKs")
        return uniqueSDKs
    }
}
