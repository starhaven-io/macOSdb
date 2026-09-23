import Darwin
import Foundation
import ZIPFoundation

extension IPSWExtractor {
    struct ExtractionBudget {
        let individualLimit: UInt64
        let totalSoFar: UInt64
        let totalLimit: UInt64
    }

    func extractBoundedEntry(
        _ entry: Entry,
        from archive: Archive,
        to destination: URL,
        budget: ExtractionBudget
    ) throws -> UInt64 {
        guard entry.uncompressedSize <= budget.individualLimit,
              entry.uncompressedSize <= budget.totalLimit,
              budget.totalSoFar <= budget.totalLimit - entry.uncompressedSize else {
            throw ScannerError.ipswExtractionFailed(reason: "Archive expansion exceeds its byte budget")
        }

        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var extractedBytes: UInt64 = 0

        let checksum: CRC32
        do {
            // The declared size already fits the budget, so bounding by it bounds both.
            checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                let chunkSize = UInt64(chunk.count)
                guard chunkSize <= entry.uncompressedSize - extractedBytes else {
                    throw ScannerError.ipswExtractionFailed(
                        reason: "Extracted data exceeded its declared size"
                    )
                }
                try handle.write(contentsOf: chunk)
                extractedBytes += chunkSize
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        guard extractedBytes == entry.uncompressedSize else {
            try? FileManager.default.removeItem(at: destination)
            throw ScannerError.ipswExtractionFailed(
                reason: "Extracted data did not match its declared size"
            )
        }
        guard checksum == entry.checksum else {
            try? FileManager.default.removeItem(at: destination)
            throw ScannerError.ipswExtractionFailed(
                reason: "Extracted data failed its CRC-32 check: \(entry.path)"
            )
        }
        return extractedBytes
    }
}
