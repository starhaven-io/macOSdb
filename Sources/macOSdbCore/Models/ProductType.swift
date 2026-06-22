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
}
