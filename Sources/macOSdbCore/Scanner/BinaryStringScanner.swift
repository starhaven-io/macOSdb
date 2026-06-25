import Foundation
import OSLog

/// Equivalent to the `strings` command — scans binary data for runs of printable ASCII characters.
///
/// Inputs are untrusted firmware binaries, so extraction is bounded: each run is
/// capped at `defaultMaxStringLength` and the streaming core (`enumerateStrings`)
/// lets callers stop early instead of materializing every run up front. See
/// `AGENTS.md` — scanner parsers must bound allocation over attacker-controlled data.
enum BinaryStringScanner {

    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "BinaryStringScanner")

    static let defaultMinLength = 4

    /// Per-run cap. Version strings are tiny; this only trips on pathological
    /// padding, where it emits a bounded prefix and skips the rest of the run so
    /// one giant printable run can't balloon a single `String` allocation.
    static let defaultMaxStringLength = 1 * 1_024 * 1_024 // 1 MiB

    /// Streams runs of printable ASCII (length ≥ `minLength`) to `body` without
    /// building an intermediate array. Each run is truncated to `maxStringLength`
    /// bytes; the remainder of an over-long run is skipped to the next delimiter.
    /// Return `false` from `body` to stop scanning early.
    static func enumerateStrings(
        from data: Data,
        minLength: Int = defaultMinLength,
        maxStringLength: Int = defaultMaxStringLength,
        _ body: (String) -> Bool
    ) {
        var current: [UInt8] = []
        var skippingRun = false

        // Returns false when the caller asked to stop.
        func flush() -> Bool {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= minLength,
                  let string = String(bytes: current, encoding: .ascii) else {
                return true
            }
            return body(string)
        }

        for byte in data {
            if byte >= 0x20, byte <= 0x7E {
                if skippingRun { continue }
                if current.count >= maxStringLength {
                    // Cap reached: emit the prefix, then skip the rest of this run.
                    if !flush() { return }
                    skippingRun = true
                    continue
                }
                current.append(byte)
            } else {
                skippingRun = false
                if !flush() { return }
            }
        }

        // Trailing run with no delimiter before EOF.
        _ = flush()
    }

    static func extractStrings(
        from data: Data,
        minLength: Int = defaultMinLength,
        maxStringLength: Int = defaultMaxStringLength
    ) -> [String] {
        var results: [String] = []
        enumerateStrings(from: data, minLength: minLength, maxStringLength: maxStringLength) { string in
            results.append(string)
            return true
        }
        return results
    }

    static func findFirst(
        in data: Data,
        matching pattern: String,
        minLength: Int = defaultMinLength
    ) -> String? {
        var result: String?

        // Swift Regex doesn't support lookbehind; fall back to NSRegularExpression.
        if let regex = try? Regex(pattern) {
            enumerateStrings(from: data, minLength: minLength) { string in
                if let match = string.firstMatch(of: regex) {
                    result = String(string[match.range])
                    return false
                }
                return true
            }
        } else if let nsRegex = try? NSRegularExpression(pattern: pattern) {
            enumerateStrings(from: data, minLength: minLength) { string in
                let range = NSRange(string.startIndex..., in: string)
                if let match = nsRegex.firstMatch(in: string, range: range),
                   let matchRange = Range(match.range, in: string) {
                    result = String(string[matchRange])
                    return false
                }
                return true
            }
        } else {
            logger.warning("Failed to compile regex pattern: \(pattern)")
        }
        return result
    }

    static func findAll(
        in data: Data,
        matching pattern: String,
        minLength: Int = defaultMinLength
    ) -> [String] {
        // Bounded by the number of pattern matches (sparse for version regexes),
        // not by the total number of printable runs in the input.
        var results: [String] = []
        if let regex = try? Regex(pattern) {
            enumerateStrings(from: data, minLength: minLength) { string in
                for match in string.matches(of: regex) {
                    results.append(String(string[match.range]))
                }
                return true
            }
        } else if let nsRegex = try? NSRegularExpression(pattern: pattern) {
            enumerateStrings(from: data, minLength: minLength) { string in
                let range = NSRange(string.startIndex..., in: string)
                nsRegex.enumerateMatches(in: string, range: range) { match, _, _ in
                    if let match, let matchRange = Range(match.range, in: string) {
                        results.append(String(string[matchRange]))
                    }
                }
                return true
            }
        } else {
            logger.warning("Failed to compile regex pattern: \(pattern)")
        }
        return results
    }
}
