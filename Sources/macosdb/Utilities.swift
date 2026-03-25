import Foundation
import macOSdbKit

nonisolated func makeDataProvider(dataURL: String?) -> DataProvider {
    if let dataURL, let url = URL(string: dataURL) {
        return DataProvider(baseURL: url)
    }
    return DataProvider()
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
