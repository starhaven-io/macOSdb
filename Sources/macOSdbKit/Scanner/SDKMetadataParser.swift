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

    // MARK: - SDK component extraction

    /// Extract component versions from SDK headers and .tbd files.
    /// `sdkUsrDir` is the `usr/` directory inside the SDK root.
    static func extractSDKComponents(from sdkUsrDir: URL) -> [Component] {
        var components: [Component] = []

        for definition in sdkComponents {
            let filePath = sdkUsrDir.appendingPathComponent(definition.path)
            guard let content = try? String(contentsOf: filePath, encoding: .utf8) else {
                logger.debug("SDK \(definition.name): file not found at \(filePath.path)")
                continue
            }

            if let version = extractVersion(from: content, using: definition) {
                logger.info("SDK \(definition.name): \(version)")
                components.append(Component(
                    name: definition.name,
                    version: version,
                    path: "/\(definition.path)",
                    source: .sdk
                ))
            } else {
                logger.debug("SDK \(definition.name): no version matched")
            }
        }

        return components
    }

    private static func extractVersion(from content: String, using definition: SDKComponentDefinition) -> String? {
        // Multi-define extraction for expat and ncurses
        if definition.pattern.contains("|") {
            return extractMultiDefineVersion(from: content, defines: definition.pattern)
        }

        guard let regex = try? Regex(definition.pattern) else {
            logger.warning("Failed to compile regex for \(definition.name): \(definition.pattern)")
            return nil
        }
        guard let match = content.firstMatch(of: regex) else {
            return nil
        }

        return definition.normalize(String(content[match.range]))
    }

    /// Extract version from multiple `#define NAME value` lines and join as "major.minor.patch".
    private static func extractMultiDefineVersion(from content: String, defines: String) -> String? {
        let names = defines.split(separator: "|").map(String.init)
        var parts: [String] = []

        for name in names {
            let pattern = #"#\s*define\s+"# + name + #"\s+(\S+)"#
            guard let regex = try? Regex(pattern) else {
                logger.warning("Failed to compile regex for multi-define: \(pattern)")
                return nil
            }
            guard let match = content.firstMatch(of: regex),
                  match.count > 1 else {
                return nil
            }
            if let value = match[1].substring {
                parts.append(String(value))
            } else {
                return nil
            }
        }

        return parts.joined(separator: ".")
    }

    // MARK: - SDK discovery

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
                // Only parse SDKs in MacOSX*.sdk directories, skip DriverKit etc.
                let sdkDir = fileURL.deletingLastPathComponent().lastPathComponent
                if fileURL.lastPathComponent == "SDKSettings.json",
                   sdkDir.hasPrefix("MacOSX"),
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
