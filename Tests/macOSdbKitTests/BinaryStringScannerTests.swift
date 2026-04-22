import Foundation
import Testing

@testable import macOSdbKit

@Suite("Binary string scanner tests")
struct BinaryStringScannerTests {

    // MARK: - extractStrings

    @Test("Returns empty for empty data")
    func emptyData() {
        #expect(BinaryStringScanner.extractStrings(from: Data()).isEmpty)
    }

    @Test("Returns empty when no byte is printable ASCII")
    func onlyNonPrintable() {
        let data = Data([0x00, 0x01, 0x1F, 0x7F, 0x80, 0xFF])
        #expect(BinaryStringScanner.extractStrings(from: data).isEmpty)
    }

    @Test("Captures a run terminated by null byte")
    func runTerminatedByNull() {
        var bytes = [UInt8]("Hello, world!".utf8)
        bytes.append(0x00)
        #expect(BinaryStringScanner.extractStrings(from: Data(bytes)) == ["Hello, world!"])
    }

    @Test("Captures a trailing run that reaches EOF without a terminator")
    func runAtEOFWithoutTerminator() {
        let bytes = [UInt8]("trailing run".utf8)
        #expect(BinaryStringScanner.extractStrings(from: Data(bytes)) == ["trailing run"])
    }

    @Test("Separates runs on any non-printable byte")
    func multipleRuns() {
        var bytes = [UInt8]("first".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "second".utf8)
        bytes.append(0x0A) // LF — not in 0x20–0x7E
        bytes.append(contentsOf: "third".utf8)
        bytes.append(0xFF) // high byte also delimits
        bytes.append(contentsOf: "fourth".utf8)
        #expect(
            BinaryStringScanner.extractStrings(from: Data(bytes))
                == ["first", "second", "third", "fourth"]
        )
    }

    @Test("Filters out runs shorter than the default minLength")
    func belowDefaultMinLength() {
        var bytes = [UInt8]("abc".utf8)  // 3 — below default 4
        bytes.append(0x00)
        bytes.append(contentsOf: "abcd".utf8)  // 4 — exactly at the default
        bytes.append(0x00)
        #expect(BinaryStringScanner.extractStrings(from: Data(bytes)) == ["abcd"])
    }

    @Test("Honors a custom minLength parameter")
    func customMinLength() {
        var bytes = [UInt8]("ab".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "abc".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "abcd".utf8)
        let data = Data(bytes)
        #expect(BinaryStringScanner.extractStrings(from: data, minLength: 2) == ["ab", "abc", "abcd"])
        #expect(BinaryStringScanner.extractStrings(from: data, minLength: 3) == ["abc", "abcd"])
        #expect(BinaryStringScanner.extractStrings(from: data, minLength: 5).isEmpty)
    }

    @Test("Includes the printable ASCII boundaries 0x20 and 0x7E")
    func printableBoundariesIncluded() {
        let bytes: [UInt8] = [0x20, 0x21, 0x7D, 0x7E] // " !}~"
        #expect(BinaryStringScanner.extractStrings(from: Data(bytes)) == [" !}~"])
    }

    @Test("Treats 0x1F and 0x7F as non-printable delimiters")
    func nonPrintableBoundariesExcluded() {
        var bytes: [UInt8] = [0x1F]
        bytes.append(contentsOf: "abcd".utf8)
        bytes.append(0x7F)
        bytes.append(contentsOf: "efgh".utf8)
        #expect(BinaryStringScanner.extractStrings(from: Data(bytes)) == ["abcd", "efgh"])
    }

    // MARK: - findFirst

    @Test("findFirst returns the matched substring, not the whole containing string")
    func findFirstReturnsMatchSubstring() {
        var bytes = [UInt8]("prefix curl 8.7.1 suffix".utf8)
        bytes.append(0x00)
        #expect(
            BinaryStringScanner.findFirst(in: Data(bytes), matching: #"\d+\.\d+\.\d+"#) == "8.7.1"
        )
    }

    @Test("findFirst returns nil when no match is present")
    func findFirstNoMatch() {
        let data = Data("hello world".utf8)
        #expect(BinaryStringScanner.findFirst(in: data, matching: #"\d+"#) == nil)
    }

    @Test("findFirst skips runs below minLength before matching")
    func findFirstRespectsMinLength() {
        // "v1" is below default minLength (4), so its digits are invisible to the regex.
        var bytes = [UInt8]("v1".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "version 42 here".utf8)
        #expect(BinaryStringScanner.findFirst(in: Data(bytes), matching: #"\d+"#) == "42")
    }

    @Test("findFirst supports lookbehind patterns")
    func findFirstLookbehind() {
        var bytes = [UInt8]("OpenSSH_9.9p2".utf8)
        bytes.append(0x00)
        #expect(
            BinaryStringScanner.findFirst(
                in: Data(bytes),
                matching: #"(?<=OpenSSH_)\d+\.\d+p\d+"#
            ) == "9.9p2"
        )
    }

    @Test("findFirst returns nil for an invalid regex pattern")
    func findFirstInvalidPattern() {
        let data = Data("anything here".utf8)
        #expect(BinaryStringScanner.findFirst(in: data, matching: "(") == nil)
    }

    // MARK: - findAll

    @Test("findAll returns every match across runs in input order")
    func findAllAcrossRuns() {
        var bytes = [UInt8]("curl 8.7.1".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "libressl 3.3.6".utf8)
        bytes.append(0x00)
        #expect(
            BinaryStringScanner.findAll(in: Data(bytes), matching: #"\d+\.\d+\.\d+"#)
                == ["8.7.1", "3.3.6"]
        )
    }

    @Test("findAll returns multiple matches within a single run")
    func findAllWithinRun() {
        let data = Data("1.0.0 and 2.0.0 and 3.0.0".utf8)
        #expect(
            BinaryStringScanner.findAll(in: data, matching: #"\d+\.\d+\.\d+"#)
                == ["1.0.0", "2.0.0", "3.0.0"]
        )
    }

    @Test("findAll returns empty when there are no matches")
    func findAllNoMatches() {
        let data = Data("no numbers here".utf8)
        #expect(BinaryStringScanner.findAll(in: data, matching: #"\d+"#).isEmpty)
    }

    @Test("findAll supports lookbehind patterns")
    func findAllLookbehind() {
        var bytes = [UInt8]("Version_1.2 and Version_3.4".utf8)
        bytes.append(0x00)
        #expect(
            BinaryStringScanner.findAll(
                in: Data(bytes),
                matching: #"(?<=Version_)\d+\.\d+"#
            ) == ["1.2", "3.4"]
        )
    }

    @Test("findAll returns empty for an invalid regex pattern")
    func findAllInvalidPattern() {
        let data = Data("anything here".utf8)
        #expect(BinaryStringScanner.findAll(in: data, matching: "(").isEmpty)
    }
}
