import Foundation
import Testing

@testable import macosdb

@Suite("ValidateCommand parsing and validation")
struct ValidateCommandTests {

    // MARK: - Argument parsing and validation
    //
    // Note: ArgumentParser's `parse(_:)` calls `validate()` automatically,
    // so validation failures surface as parse errors here.

    @Test("Parses multiple archive paths")
    func parsesMultipleArchives() throws {
        let cmd = try ValidateCommand.parse(["a.ipsw", "b.ipsw", "c.xip"])
        #expect(cmd.archivePaths == ["a.ipsw", "b.ipsw", "c.xip"])
        #expect(cmd.dir == nil)
        #expect(cmd.rehash == false)
    }

    @Test("Parses --dir and --rehash")
    func parsesDirAndRehash() throws {
        let cmd = try ValidateCommand.parse(["--dir", "/tmp/archives", "--rehash"])
        #expect(cmd.dir == "/tmp/archives")
        #expect(cmd.rehash == true)
    }

    @Test("Parse succeeds with at least one archive path")
    func validateWithArchivePath() throws {
        _ = try ValidateCommand.parse(["a.ipsw"])
    }

    @Test("Parse succeeds with --dir")
    func validateWithDir() throws {
        _ = try ValidateCommand.parse(["--dir", "/tmp/archives"])
    }

    @Test("Parse rejects empty inputs")
    func validateRejectsEmpty() {
        #expect(throws: (any Error).self) {
            _ = try ValidateCommand.parse([])
        }
    }
}
