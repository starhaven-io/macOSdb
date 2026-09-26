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

    @Test("Terminal output escapes C0, DEL, and C1 controls but keeps other text")
    func terminalSafeEscapesControls() {
        #expect(terminalSafe("8.7.1\r9.9.9") == "8.7.1\\u{D}9.9.9")
        #expect(terminalSafe("\u{1B}]0;title\u{07}\u{7F}\u{9B}2J") == "\\u{1B}]0;title\\u{7}\\u{7F}\\u{9B}2J")
        #expect(terminalSafe("M4 Pro — Darwin 24.0.0 ↑") == "M4 Pro — Darwin 24.0.0 ↑")
    }

    @Test("Data providers reject remote schemes other than HTTPS")
    func dataProviderRejectsInsecureRemoteScheme() {
        #expect(throws: (any Error).self) {
            _ = try makeDataProvider(dataURL: "http://example.test/api/v1")
        }
        #expect(throws: (any Error).self) {
            _ = try makeDataProvider(dataURL: "file:///tmp/macosdb-data")
        }
    }
}
