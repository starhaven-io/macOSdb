import Foundation
import Testing

@testable import macOSdbKit

@Suite("ProductType tests")
struct ProductTypeTests {

    // MARK: - Display names

    @Test("Display names for all product types")
    func displayNames() {
        #expect(ProductType.macOS.displayName == "macOS")
        #expect(ProductType.xcode.displayName == "Xcode")
    }

    // MARK: - Short names / raw values

    @Test("Short names match raw values")
    func shortNames() {
        #expect(ProductType.macOS.shortName == "macOS")
        #expect(ProductType.xcode.shortName == "Xcode")
    }

    // MARK: - Data directories

    @Test("Data directories for each product type")
    func dataDirectories() {
        #expect(ProductType.macOS.dataDirectory == "macos")
        #expect(ProductType.xcode.dataDirectory == "xcode")
    }

    // MARK: - File prefixes

    @Test("File prefixes for each product type")
    func filePrefixes() {
        #expect(ProductType.macOS.filePrefix == "macOS")
        #expect(ProductType.xcode.filePrefix == "Xcode")
    }

    // MARK: - Codable round-trip

    @Test("JSON encoding uses raw values")
    func jsonEncoding() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(ProductType.xcode)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"Xcode\"")
    }

    @Test("JSON decoding from raw values")
    func jsonDecoding() throws {
        let decoder = JSONDecoder()
        let macOS = try decoder.decode(ProductType.self, from: Data("\"macOS\"".utf8))
        #expect(macOS == .macOS)

        let xcode = try decoder.decode(ProductType.self, from: Data("\"Xcode\"".utf8))
        #expect(xcode == .xcode)
    }

    @Test("JSON round-trip for all cases")
    func jsonRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for productType in ProductType.allCases {
            let data = try encoder.encode(productType)
            let decoded = try decoder.decode(ProductType.self, from: data)
            #expect(decoded == productType)
        }
    }

    // MARK: - CaseIterable

    @Test("All cases are present")
    func allCases() {
        #expect(ProductType.allCases.count == 2)
        #expect(ProductType.allCases.contains(.macOS))
        #expect(ProductType.allCases.contains(.xcode))
    }
}
