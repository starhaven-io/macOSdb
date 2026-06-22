package struct VersionComparison: Sendable, Codable {
    package let from: Release
    package let to: Release
    package let changes: [ComponentChange]
    package let addedComponents: [Component]
    package let removedComponents: [Component]

    package var changedComponents: [ComponentChange] {
        changes.filter { $0.direction != .unchanged }
    }

    package var upgradedComponents: [ComponentChange] {
        changes.filter { $0.direction == .upgraded }
    }

    package var downgradedComponents: [ComponentChange] {
        changes.filter { $0.direction == .downgraded }
    }

    package var summary: String {
        let parts = [
            "\(upgradedComponents.count) upgraded",
            "\(downgradedComponents.count) downgraded",
            "\(addedComponents.count) added",
            "\(removedComponents.count) removed"
        ]
        return parts.joined(separator: ", ")
    }
}

package struct ComponentChange: Identifiable, Sendable, Codable {
    package var id: String { name }

    package let name: String
    package let fromVersion: String
    package let toVersion: String
    package let direction: ChangeDirection
}

package enum ChangeDirection: String, Sendable, Codable {
    case upgraded
    case downgraded
    case unchanged
}
