import Foundation

/// Metadata about a macOS SDK bundled with Xcode.
package struct SDKInfo: Codable, Hashable, Sendable, Identifiable {
    package var id: String { sdkVersion }

    /// SDK version (e.g. "15.2").
    package let sdkVersion: String

    /// SDK build number (e.g. "24C101").
    package let buildVersion: String?

    package init(sdkVersion: String, buildVersion: String? = nil) {
        self.sdkVersion = sdkVersion
        self.buildVersion = buildVersion
    }
}
