import Foundation
import Testing

@testable import macosdb

@Suite("ListCommand parsing")
struct ListCommandTests {

    @Test("Parses with no arguments")
    func parsesEmpty() throws {
        let cmd = try ListCommand.parse([])
        #expect(cmd.product == nil)
        #expect(cmd.major == nil)
        #expect(cmd.json == false)
        #expect(cmd.dataURL == nil)
    }

    @Test("Parses --product, --major, --json, --data-url")
    func parsesAllOptions() throws {
        let cmd = try ListCommand.parse([
            "--product", "xcode",
            "--major", "16",
            "--json",
            "--data-url", "https://example.com/api/v1"
        ])
        #expect(cmd.product == "xcode")
        #expect(cmd.major == 16)
        #expect(cmd.json == true)
        #expect(cmd.dataURL == "https://example.com/api/v1")
    }

    @Test("Rejects non-integer --major")
    func rejectsNonIntegerMajor() {
        #expect(throws: (any Error).self) {
            _ = try ListCommand.parse(["--major", "fifteen"])
        }
    }
}
