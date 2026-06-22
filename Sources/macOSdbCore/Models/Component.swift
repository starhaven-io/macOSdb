import Foundation

/// A single open source component extracted from a macOS release.
package struct Component: Codable, Identifiable, Hashable, Sendable {
    package var id: String { "\(name):\(path)" }

    package let name: String
    package let version: String?
    package let path: String
    package let source: ComponentSource

    package init(
        name: String,
        version: String?,
        path: String,
        source: ComponentSource = .filesystem
    ) {
        self.name = name
        self.version = version
        self.path = path
        self.source = source
    }

    package var displayVersion: String {
        version ?? "unknown"
    }
}

package enum ComponentSource: String, Codable, Hashable, Sendable {
    case filesystem
    case dyldCache
    case sdk
}
