import Foundation

public enum VersionComparer {
    public static func compare(
        from: Release,
        to target: Release
    ) -> VersionComparison {
        let fromMap = Dictionary(from.components.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let toMap = Dictionary(target.components.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        let allNames = Set(fromMap.keys).union(toMap.keys)

        var changes: [ComponentChange] = []
        var added: [Component] = []
        var removed: [Component] = []

        for name in allNames.sorted() {
            switch (fromMap[name], toMap[name]) {
            case let (.some(fromComp), .some(toComp)):
                let fromVer = fromComp.version ?? ""
                let toVer = toComp.version ?? ""
                let direction = compareVersionStrings(fromVer, toVer)
                changes.append(ComponentChange(
                    name: name,
                    fromVersion: fromVer,
                    toVersion: toVer,
                    direction: direction
                ))
            case let (nil, .some(toComp)):
                added.append(toComp)
            case let (.some(fromComp), nil):
                removed.append(fromComp)
            case (nil, nil):
                break // unreachable
            }
        }

        return VersionComparison(
            from: from,
            to: target,
            changes: changes,
            addedComponents: added,
            removedComponents: removed
        )
    }

    /// Supports dotted versions ("8.7.1") and suffix versions ("9.8p1").
    public static func compareVersionStrings(_ lhs: String, _ rhs: String) -> ChangeDirection {
        let lhsParts = parseVersion(lhs)
        let rhsParts = parseVersion(rhs)

        let maxLen = max(lhsParts.count, rhsParts.count)

        for idx in 0..<maxLen {
            let lhsPart = idx < lhsParts.count ? lhsParts[idx] : 0
            let rhsPart = idx < rhsParts.count ? rhsParts[idx] : 0

            if lhsPart < rhsPart { return .upgraded }
            if lhsPart > rhsPart { return .downgraded }
        }

        return .unchanged
    }

    private static func parseVersion(_ version: String) -> [Int] {
        // Strip parenthetical suffixes like "(from int 21209)"
        let cleaned = version.replacingOccurrences(
            of: #"\s*\(.*\)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        // Split on dots and common separators
        return cleaned.split(separator: ".").flatMap { segment -> [Int] in
            // Handle "9p1" → [9, 1] and "8" → [8]
            let str = String(segment)
            return str.split { !$0.isNumber }.compactMap { Int($0) }
        }
    }
}
