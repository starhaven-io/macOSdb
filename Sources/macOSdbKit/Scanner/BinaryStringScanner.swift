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
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let strings = extractStrings(from: data, minLength: minLength)
        for string in strings {
            let range = NSRange(string.startIndex..., in: string)
            if let match = regex.firstMatch(in: string, range: range) {
                if let matchRange = Range(match.range, in: string) {
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
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var results: [String] = []
        let strings = extractStrings(from: data, minLength: minLength)
        for string in strings {
            let range = NSRange(string.startIndex..., in: string)
            regex.enumerateMatches(in: string, range: range) { match, _, _ in
                if let match, let matchRange = Range(match.range, in: string) {
                    results.append(String(string[matchRange]))
                }
            }
        }
        return results
    }
}
