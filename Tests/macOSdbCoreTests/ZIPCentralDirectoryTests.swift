import Foundation
import Testing
import ZIPFoundation

@testable import macOSdbCore

@Suite("ZIP central directory tests")
struct ZIPCentralDirectoryTests {
    @Test("The declared count matches what ZIPFoundation iterates for an intact archive")
    func declaredCountMatchesIteration() throws {
        let url = try temporaryFile(named: "intact.zip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let archive = try Archive(url: url, accessMode: .create)
        for name in ["a", "b", "c"] {
            let contents = Data(name.utf8)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(contents.count)) { _, _ in contents }
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(try ZIPCentralDirectory.declaredEntryCount(in: handle) == 3)
        #expect(throws: ZIPIntegrityError.unreadEntries(declared: 3, read: 2)) {
            try ZIPCentralDirectory.requireAllEntriesRead(2, in: handle)
        }
    }

    @Test("A ZIP64 record overrides the classic count only when ZIPFoundation would accept it")
    func readsZIP64CountLikeZIPFoundation() throws {
        for (version, expected) in [(UInt16(45), UInt64(70_000)), (UInt16(20), UInt64(0xFFFF))] {
            let url = try temporaryFile(named: "zip64-\(version).zip")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try zip64Tail(recordVersion: version, entries: 70_000).write(to: url)

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            #expect(try ZIPCentralDirectory.declaredEntryCount(in: handle) == expected)
        }
    }

    @Test("Files without an end-of-central-directory record are rejected")
    func rejectsMissingEndRecord() throws {
        let url = try temporaryFile(named: "not-a.zip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(repeating: 0, count: 64).write(to: url)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(throws: ZIPIntegrityError.missingEndRecord) {
            try ZIPCentralDirectory.declaredEntryCount(in: handle)
        }
    }

    private func zip64Tail(recordVersion: UInt16, entries: UInt64) -> Data {
        var data = Data([0])
        data.append(littleEndian: UInt32(0x0606_4B50))
        data.append(littleEndian: UInt64(44))
        data.append(littleEndian: UInt16(45))
        data.append(littleEndian: recordVersion)
        data.append(littleEndian: UInt32(0))
        data.append(littleEndian: UInt32(0))
        data.append(littleEndian: entries)
        data.append(littleEndian: entries)
        data.append(littleEndian: UInt64(0))
        data.append(littleEndian: UInt64(0))
        data.append(littleEndian: UInt32(0x0706_4B50))
        data.append(littleEndian: UInt32(0))
        data.append(littleEndian: UInt64(1))
        data.append(littleEndian: UInt32(1))
        data.append(littleEndian: UInt32(0x0605_4B50))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt16(0xFFFF))
        data.append(littleEndian: UInt16(0xFFFF))
        data.append(littleEndian: UInt32(0xFFFF_FFFF))
        data.append(littleEndian: UInt32(0xFFFF_FFFF))
        data.append(littleEndian: UInt16(0))
        return data
    }

    private func temporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-zip-cd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}

private extension Data {
    mutating func append<Value: FixedWidthInteger>(littleEndian value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
