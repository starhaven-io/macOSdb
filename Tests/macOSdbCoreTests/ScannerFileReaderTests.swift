import Foundation
import Testing

@testable import macOSdbCore

@Suite("Scanner file reader tests")
struct ScannerFileReaderTests {
    @Test("Reads bounded files and rejects oversized inputs")
    func enforcesSizeLimit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input")
        try Data("12345".utf8).write(to: file)

        #expect(try ScannerFileReader.data(at: file, confinedTo: root, maxBytes: 5).count == 5)
        #expect(throws: (any Error).self) {
            _ = try ScannerFileReader.data(at: file, confinedTo: root, maxBytes: 4)
        }
    }

    @Test("Rejects symlinks escaping the extracted archive")
    func rejectsEscapingSymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("input")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            _ = try ScannerFileReader.data(at: link, confinedTo: root)
        }
    }

    @Test("Allows symlinks whose resolved target remains inside the archive")
    func allowsInternalSymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("inside".utf8).write(to: target)
        let link = root.appendingPathComponent("input")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(try ScannerFileReader.string(at: link, confinedTo: root) == "inside")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-file-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
