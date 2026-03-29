import Foundation
import OSLog

public enum ComponentExtractor {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "ComponentExtractor")

    @concurrent
    public static func extract(from data: Data, using definition: ComponentDefinition) async -> Component? {
        logger.debug("Extracting \(definition.name) from \(data.count) bytes")

        switch definition.strategy {
        case .regex:
            return extractWithRegex(from: data, using: definition)
        case .integerDecode:
            return extractWithIntegerDecode(from: data, using: definition)
        }
    }

    // MARK: - Regex strategy

    private static func extractWithRegex(
        from data: Data,
        using definition: ComponentDefinition
    ) -> Component? {
        let minLength = definition.minLength ?? BinaryStringScanner.defaultMinLength
        guard let rawMatch = BinaryStringScanner.findFirst(
            in: data, matching: definition.pattern, minLength: minLength
        ) else {
            logger.debug("\(definition.name): no version found")
            return nil
        }

        let version = definition.normalize(rawMatch)

        logger.info("\(definition.name): \(version)")
        return Component(
            name: definition.name,
            version: version,
            path: canonicalPath(for: definition),
            source: definition.source
        )
    }

    // MARK: - Integer decode strategy (libxml2)

    private static func extractWithIntegerDecode(
        from data: Data,
        using definition: ComponentDefinition
    ) -> Component? {
        let minLength = definition.minLength ?? BinaryStringScanner.defaultMinLength
        let matches = BinaryStringScanner.findAll(in: data, matching: definition.pattern, minLength: minLength)
        let uniqueMatches = Array(Set(matches)).sorted()

        // Take the last (highest) match — typically the actual version
        guard let intString = uniqueMatches.last,
              let intValue = Int(intString) else {
            logger.debug("\(definition.name): no integer version found")
            return nil
        }

        // Decode: MAJOR * 10000 + MINOR * 100 + PATCH
        let major = intValue / 10_000
        let minor = (intValue % 10_000) / 100
        let patch = intValue % 100
        let version = "\(major).\(minor).\(patch)"

        logger.info("\(definition.name): \(version) (decoded from \(intValue))")
        return Component(
            name: definition.name,
            version: version,
            path: canonicalPath(for: definition),
            source: definition.source
        )
    }

    private static func canonicalPath(for definition: ComponentDefinition) -> String {
        definition.path.hasPrefix("/") ? definition.path : "/\(definition.path)"
    }
}
