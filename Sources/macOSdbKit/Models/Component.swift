import Foundation

/// A single open source component extracted from a macOS release.
public struct Component: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(name):\(path)" }

    public let name: String
    public let version: String?
    public let path: String
    public let source: ComponentSource

    public init(
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

    public var displayVersion: String {
        version ?? "unknown"
    }
}

public enum ComponentSource: String, Codable, Hashable, Sendable {
    case filesystem
    case dyldCache
}
