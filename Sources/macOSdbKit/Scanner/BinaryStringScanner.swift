import Foundation

/// Equivalent to the `strings` command — scans binary data for runs of printable ASCII characters.
public enum BinaryStringScanner {

    public static let defaultMinLength = 4

    public static func extractStrings(from data: Data, minLength: Int = defaultMinLength) -> [String] {
        var results: [String] = []
        var current: [UInt8] = []

        for byte in data {
            if byte >= 0x20, byte <= 0x7E {
                current.append(byte)
            } else {
                if current.count >= minLength {
                    if let string = String(bytes: current, encoding: .ascii) {
                        results.append(string)
                    }
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        // Handle trailing string (no null terminator at end of data)
        if current.count >= minLength {
            if let string = String(bytes: current, encoding: .ascii) {
                results.append(string)
            }
        }

        return results
    }

    public static func findFirst(
        in data: Data,
        matching pattern: String,
        minLength: Int = defaultMinLength
    ) -> String? {
        // Swift Regex doesn't support lookbehind; fall back to NSRegularExpression
        if let regex = try? Regex(pattern) {
            for string in extractStrings(from: data, minLength: minLength) {
                if let match = string.firstMatch(of: regex) {
                    return String(string[match.range])
                }
            }
        } else if let nsRegex = try? NSRegularExpression(pattern: pattern) {
            for string in extractStrings(from: data, minLength: minLength) {
                let range = NSRange(string.startIndex..., in: string)
                if let match = nsRegex.firstMatch(in: string, range: range),
                   let matchRange = Range(match.range, in: string) {
                    return String(string[matchRange])
                }
            }
        }
        return nil
    }

    public static func findAll(
        in data: Data,
        matching pattern: String,
        minLength: Int = defaultMinLength
    ) -> [String] {
        var results: [String] = []
        if let regex = try? Regex(pattern) {
            for string in extractStrings(from: data, minLength: minLength) {
                for match in string.matches(of: regex) {
                    results.append(String(string[match.range]))
                }
            }
        } else if let nsRegex = try? NSRegularExpression(pattern: pattern) {
            for string in extractStrings(from: data, minLength: minLength) {
                let range = NSRange(string.startIndex..., in: string)
                nsRegex.enumerateMatches(in: string, range: range) { match, _, _ in
                    if let match, let matchRange = Range(match.range, in: string) {
                        results.append(String(string[matchRange]))
                    }
                }
            }
        }
        return results
    }
}
