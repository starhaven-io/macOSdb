import Foundation
import macOSdbKit

nonisolated func makeDataProvider(dataURL: String?) -> DataProvider {
    if let dataURL, let url = URL(string: dataURL) {
        return DataProvider(baseURL: url)
    }
    return DataProvider()
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

/// Parses a product type string from CLI `--product` option.
/// Accepts case-insensitive values: "macOS", "xcode".
/// Defaults to `.macOS` when nil.
nonisolated func parseProductType(_ value: String?) -> ProductType {
    guard let value else { return .macOS }
    switch value.lowercased() {
    case "macos": return .macOS
    case "xcode": return .xcode
    default:
        FileHandle.standardError.write(Data("Warning: Unknown product type '\(value)', defaulting to macOS\n".utf8))
        return .macOS
    }
}
