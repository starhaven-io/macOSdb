import Foundation
import macOSdbCore
import Testing

@testable import macosdb

@Suite("CLI utility helpers")
struct UtilitiesTests {
    @Test("parseProductType defaults to macOS")
    func parseProductTypeDefaultsToMacOS() throws {
        #expect(try parseProductType(nil) == .macOS)
    }

    @Test("parseProductType accepts supported products case-insensitively")
    func parseProductTypeAcceptsSupportedProducts() throws {
        #expect(try parseProductType("macos") == .macOS)
        #expect(try parseProductType("macOS") == .macOS)
        #expect(try parseProductType("xcode") == .xcode)
        #expect(try parseProductType("XCODE") == .xcode)
    }

    @Test("parseProductType rejects unsupported products")
    func parseProductTypeRejectsUnsupportedProducts() {
        #expect(throws: (any Error).self) {
            _ = try parseProductType("ios")
        }
    }
}
