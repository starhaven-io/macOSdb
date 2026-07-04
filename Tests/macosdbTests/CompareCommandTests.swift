import Foundation
import Testing

@testable import macosdb

@Suite("CompareCommand parsing")
struct CompareCommandTests {
    @Test("Parses from and to versions with defaults")
    func parsesVersionsWithDefaults() throws {
        let cmd = try CompareCommand.parse(["14.6.1", "15.6.1"])

        #expect(cmd.fromVersion == "14.6.1")
        #expect(cmd.toVersion == "15.6.1")
        #expect(cmd.product == nil)
        #expect(cmd.changed == false)
        #expect(cmd.json == false)
        #expect(cmd.dataURL == nil)
    }

    @Test("Parses product, changed, JSON, and data URL options")
    func parsesAllOptions() throws {
        let cmd = try CompareCommand.parse([
            "15.4",
            "16.0",
            "--product", "xcode",
            "--changed",
            "--json",
            "--data-url", "https://example.com/api/v1"
        ])

        #expect(cmd.fromVersion == "15.4")
        #expect(cmd.toVersion == "16.0")
        #expect(cmd.product == "xcode")
        #expect(cmd.changed == true)
        #expect(cmd.json == true)
        #expect(cmd.dataURL == "https://example.com/api/v1")
    }

    @Test("Missing comparison endpoint is rejected")
    func missingComparisonEndpointRejected() {
        #expect(throws: (any Error).self) {
            _ = try CompareCommand.parse(["15.4"])
        }
    }
}
