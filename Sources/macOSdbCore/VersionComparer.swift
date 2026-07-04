import Foundation

package enum VersionComparer {
    package static func compare(
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
    package static func compareVersionStrings(_ lhs: String, _ rhs: String) -> ChangeDirection {
        let lhsParts = parseVersion(lhs)
        let rhsParts = parseVersion(rhs)

        guard !lhsParts.isEmpty, !rhsParts.isEmpty else {
            return .unchanged
        }

        let maxLen = max(lhsParts.count, rhsParts.count)

        for idx in 0..<maxLen {
            switch compareToken(
                idx < lhsParts.count ? lhsParts[idx] : nil,
                idx < rhsParts.count ? rhsParts[idx] : nil
            ) {
            case .orderedAscending:
                return .upgraded
            case .orderedDescending:
                return .downgraded
            case .orderedSame:
                continue
            }
        }

        return .unchanged
    }

    private enum VersionToken: Equatable {
        case number(Int)
        case letters(String)
    }

    private static func parseVersion(_ version: String) -> [VersionToken] {
        // Strip parenthetical suffixes like "(from int 21209)"
        let cleaned = version.replacingOccurrences(
            of: #"\s*\(.*\)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        var tokens: [VersionToken] = []
        var index = cleaned.startIndex

        while index < cleaned.endIndex {
            let character = cleaned[index]

            if character.isNumber {
                let start = index
                while index < cleaned.endIndex, cleaned[index].isNumber {
                    index = cleaned.index(after: index)
                }
                tokens.append(.number(Int(cleaned[start..<index]) ?? 0))
                continue
            }

            if character.isLetter, !tokens.isEmpty {
                let start = index
                while index < cleaned.endIndex, cleaned[index].isLetter {
                    index = cleaned.index(after: index)
                }
                tokens.append(.letters(String(cleaned[start..<index]).lowercased()))
                continue
            }

            index = cleaned.index(after: index)
        }

        return tokens
    }

    private static func compareToken(_ lhs: VersionToken?, _ rhs: VersionToken?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (.some(.number(0)), nil), (nil, .some(.number(0))):
            return .orderedSame
        case (nil, .some):
            return .orderedAscending
        case (.some, nil):
            return .orderedDescending
        case let (.some(.number(lhsValue)), .some(.number(rhsValue))):
            return compare(lhsValue, rhsValue)
        case let (.some(.letters(lhsValue)), .some(.letters(rhsValue))):
            return compare(lhsValue, rhsValue)
        case let (.some(.number(lhsValue)), .some(.letters)):
            return lhsValue == 0 ? .orderedAscending : .orderedDescending
        case let (.some(.letters), .some(.number(rhsValue))):
            return rhsValue == 0 ? .orderedDescending : .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }
}
