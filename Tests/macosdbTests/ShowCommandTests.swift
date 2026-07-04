import Foundation
import Testing

@testable import macosdb

@Suite("ShowCommand parsing")
struct ShowCommandTests {
    @Test("Parses required version with defaults")
    func parsesVersionWithDefaults() throws {
        let cmd = try ShowCommand.parse(["15.6.1"])

        #expect(cmd.version == "15.6.1")
        #expect(cmd.product == nil)
        #expect(cmd.component == nil)
        #expect(cmd.detailed == false)
        #expect(cmd.json == false)
        #expect(cmd.dataURL == nil)
    }

    @Test("Parses product, component, detail, JSON, and data URL options")
    func parsesAllOptions() throws {
        let cmd = try ShowCommand.parse([
            "16.0",
            "--product", "xcode",
            "--component", "Swift",
            "--detailed",
            "--json",
            "--data-url", "/tmp/macosdb-data"
        ])

        #expect(cmd.version == "16.0")
        #expect(cmd.product == "xcode")
        #expect(cmd.component == "Swift")
        #expect(cmd.detailed == true)
        #expect(cmd.json == true)
        #expect(cmd.dataURL == "/tmp/macosdb-data")
    }

    @Test("Missing version is rejected")
    func missingVersionRejected() {
        #expect(throws: (any Error).self) {
            _ = try ShowCommand.parse([])
        }
    }
}
