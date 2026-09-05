import Foundation

/// The type of Apple developer product being cataloged.
package enum ProductType: String, Codable, Sendable, CaseIterable {
    case macOS
    case xcode = "Xcode"

    /// Human-readable display name.
    package var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .xcode: "Xcode"
        }
    }

    /// Subdirectory under `data/` for this product's releases.
    package var dataDirectory: String {
        switch self {
        case .macOS: "macos"
        case .xcode: "xcode"
        }
    }

    /// File prefix for per-release JSON files.
    package var filePrefix: String {
        switch self {
        case .macOS: "macOS"
        case .xcode: "Xcode"
        }
    }

    package func canonicalDataFile(osVersion: String, buildNumber: String) -> String? {
        guard osVersion.wholeMatch(of: /[0-9]+\.[0-9]+(?:\.[0-9]+)?/) != nil,
              buildNumber.wholeMatch(of: /[0-9]+[A-Z][0-9]+[a-z]?/) != nil,
              let major = osVersion.split(separator: ".", maxSplits: 1).first else {
            return nil
        }
        return "releases/\(major)/\(filePrefix)-\(osVersion)-\(buildNumber).json"
    }
}
