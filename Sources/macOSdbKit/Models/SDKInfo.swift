import Foundation

/// Metadata about a macOS SDK bundled with Xcode.
public struct SDKInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String { sdkVersion }

    /// SDK version (e.g. "15.2").
    public let sdkVersion: String

    /// SDK build number (e.g. "24C101").
    public let buildVersion: String?

    public init(sdkVersion: String, buildVersion: String? = nil) {
        self.sdkVersion = sdkVersion
        self.buildVersion = buildVersion
    }
}
