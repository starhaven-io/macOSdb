import Foundation
import Testing

@testable import macosdb

@Suite("CompletionsCommand parsing and validation")
struct CompletionsCommandTests {
    @Test("Parses the requested shell")
    func parsesShell() throws {
        let cmd = try CompletionsCommand.parse(["zsh"])

        #expect(cmd.shell == "zsh")
    }

    @Test("Missing shell is rejected")
    func missingShellRejected() {
        #expect(throws: (any Error).self) {
            _ = try CompletionsCommand.parse([])
        }
    }

    @Test("Unsupported shell is rejected when run")
    func unsupportedShellRejected() throws {
        let cmd = try CompletionsCommand.parse(["pwsh"])

        #expect(throws: (any Error).self) {
            try cmd.run()
        }
    }
}
