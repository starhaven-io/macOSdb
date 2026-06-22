import ArgumentParser
import Foundation
import macOSdbCore

/// Builds a DataProvider from `--data-url`: a local directory path, an https URL, or
/// the default production endpoint when unset. Throws rather than silently falling
/// back to production on an unparsable value, and reads a scheme-less local path as
/// a file URL instead of a doomed network fetch.
nonisolated func makeDataProvider(dataURL: String?) throws -> DataProvider {
    guard let dataURL else { return DataProvider() }
    if FileManager.default.fileExists(atPath: dataURL) {
        return DataProvider(baseURL: URL(fileURLWithPath: dataURL))
    }
    guard let url = URL(string: dataURL), url.scheme != nil else {
        throw ValidationError(
            "Invalid --data-url '\(dataURL)'. Use an https URL or the path to a local data directory."
        )
    }
    return DataProvider(baseURL: url)
}

/// Writes an "Error: …" line to standard error. CLI errors belong on stderr so
/// they don't contaminate the stdout stream consumers parse (e.g. --json output).
nonisolated func printError(_ message: String) {
    FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
}

/// Writes a status/progress line to standard error.
nonisolated func printStatus(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Writes an in-place progress line (carriage return, no newline) to standard error.
nonisolated func printInline(_ message: String) {
    let line = message.isEmpty ? "\r\u{1B}[K" : "\r\(message)"
    FileHandle.standardError.write(Data(line.utf8))
}

nonisolated func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

/// Parses a product type from the CLI `--product` option. Accepts case-insensitive
/// "macOS"/"xcode", defaults to `.macOS` when nil, and throws on an unrecognized
/// value rather than silently defaulting (which fed scripts the wrong product).
nonisolated func parseProductType(_ value: String?) throws -> ProductType {
    guard let value else { return .macOS }
    switch value.lowercased() {
    case "macos": return .macOS
    case "xcode": return .xcode
    default:
        throw ValidationError("Unknown product '\(value)'. Expected 'macos' or 'xcode'.")
    }
}
