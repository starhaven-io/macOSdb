import Foundation

/// The type of Apple developer product being cataloged.
public enum ProductType: String, Codable, Sendable, CaseIterable {
    case macOS
    case xcode = "Xcode"

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .xcode: "Xcode"
        }
    }

    /// Short label for use in file paths and CLI output.
    public var shortName: String {
        rawValue
    }

    /// Subdirectory under `data/` for this product's releases.
    public var dataDirectory: String {
        switch self {
        case .macOS: "macos"
        case .xcode: "xcode"
        }
    }

    /// File prefix for per-release JSON files.
    public var filePrefix: String {
        switch self {
        case .macOS: "macOS"
        case .xcode: "Xcode"
        }
    }
}
