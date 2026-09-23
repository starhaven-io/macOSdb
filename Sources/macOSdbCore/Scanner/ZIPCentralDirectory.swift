import Foundation

/// ZIPFoundation's entry iterator ends without an error at the first central
/// directory record or local header it cannot read, so a damaged archive reads
/// as a shorter one. Callers compare the entries they iterated with the count
/// declared at the end of the archive, located the way ZIPFoundation locates it.
package enum ZIPCentralDirectory {
    private static let endRecordSignature: UInt32 = 0x0605_4B50
    private static let zip64RecordSignature: UInt32 = 0x0606_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let endRecordSize: UInt64 = 22
    private static let zip64RecordSize: UInt64 = 56
    private static let zip64LocatorSize: UInt64 = 20
    private static let maxCommentLength: UInt64 = 0xFFFF
    private static let zip64MinimumVersion: UInt16 = 45

    package static func requireAllEntriesRead(_ entriesRead: Int, in handle: FileHandle) throws {
        let declared = try declaredEntryCount(in: handle)
        guard UInt64(entriesRead) == declared else {
            throw ZIPIntegrityError.unreadEntries(declared: declared, read: entriesRead)
        }
    }

    static func declaredEntryCount(in handle: FileHandle) throws -> UInt64 {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= endRecordSize else { throw ZIPIntegrityError.missingEndRecord }
        let windowSize = min(fileSize, endRecordSize + maxCommentLength)
        let windowStart = fileSize - windowSize
        let window = try read(handle, at: windowStart, count: windowSize)
        guard let position = stride(from: Int(windowSize - endRecordSize), through: 0, by: -1)
            .first(where: { window.littleEndian(UInt32.self, at: $0) == endRecordSignature }) else {
            throw ZIPIntegrityError.missingEndRecord
        }

        // ZIPFoundation reads a ZIP64 record only from the fixed position before its locator.
        let endRecordOffset = windowStart + UInt64(position)
        if endRecordOffset > zip64LocatorSize + zip64RecordSize {
            let recordOffset = endRecordOffset - zip64LocatorSize - zip64RecordSize
            let zip64 = try read(handle, at: recordOffset, count: zip64RecordSize + 4)
            if zip64.littleEndian(UInt32.self, at: 0) == zip64RecordSignature,
               zip64.littleEndian(UInt16.self, at: 14) >= zip64MinimumVersion,
               zip64.littleEndian(UInt32.self, at: Int(zip64RecordSize)) == zip64LocatorSignature {
                return zip64.littleEndian(UInt64.self, at: 32)
            }
        }
        return UInt64(window.littleEndian(UInt16.self, at: position + 10))
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: Int(count)), data.count == Int(count) else {
            throw ZIPIntegrityError.missingEndRecord
        }
        return data
    }
}

package enum ZIPIntegrityError: LocalizedError, Equatable {
    case missingEndRecord
    case unreadEntries(declared: UInt64, read: Int)

    package var errorDescription: String? {
        switch self {
        case .missingEndRecord:
            "ZIP end-of-central-directory record is missing or unreadable"
        case .unreadEntries(let declared, let read):
            "ZIP central directory declares \(declared) entries but only \(read) could be read"
        }
    }
}

private extension Data {
    func littleEndian<Value: FixedWidthInteger>(_: Value.Type, at offset: Int) -> Value {
        (0..<MemoryLayout<Value>.size).reversed().reduce(Value.zero) { value, index in
            value << 8 | Value(self[startIndex + offset + index])
        }
    }
}
