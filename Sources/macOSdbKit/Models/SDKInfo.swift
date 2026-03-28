import Foundation

/// Metadata about a macOS SDK bundled with Xcode.
public struct SDKInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String { sdkVersion }

    /// SDK version (e.g. "15.2").
    public let sdkVersion: String

    public init(sdkVersion: String) {
        self.sdkVersion = sdkVersion
    }
}
