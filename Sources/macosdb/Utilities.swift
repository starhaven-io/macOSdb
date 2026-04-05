import Foundation
import macOSdbKit

nonisolated func makeDataProvider(dataURL: String?) -> DataProvider {
    if let dataURL, let url = URL(string: dataURL) {
        return DataProvider(baseURL: url)
    }
    return DataProvider()
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
