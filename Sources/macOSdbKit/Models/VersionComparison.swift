public struct VersionComparison: Sendable, Codable {
    public let from: Release
    public let to: Release
    public let changes: [ComponentChange]
    public let addedComponents: [Component]
    public let removedComponents: [Component]

    public var changedComponents: [ComponentChange] {
        changes.filter { $0.direction != .unchanged }
    }

    public var upgradedComponents: [ComponentChange] {
        changes.filter { $0.direction == .upgraded }
    }

    public var downgradedComponents: [ComponentChange] {
        changes.filter { $0.direction == .downgraded }
    }

    public var summary: String {
        let parts = [
            "\(upgradedComponents.count) upgraded",
            "\(downgradedComponents.count) downgraded",
            "\(addedComponents.count) added",
            "\(removedComponents.count) removed"
        ]
        return parts.joined(separator: ", ")
    }
}

public struct ComponentChange: Identifiable, Sendable, Codable {
    public var id: String { name }

    public let name: String
    public let fromVersion: String
    public let toVersion: String
    public let direction: ChangeDirection
}

public enum ChangeDirection: String, Sendable, Codable {
    case upgraded
    case downgraded
    case unchanged
}
