import Compression
import Foundation
import OSLog

/// Decodes IM4P (IMG4 Payload) containers commonly used to wrap Apple firmware
/// files including kernelcaches. Strips the DER/ASN.1 envelope and decompresses
/// the payload (typically LZFSE compressed on Apple Silicon).
///
/// IM4P DER structure:
/// ```
/// SEQUENCE {
///     UTF8STRING "IM4P"
///     UTF8STRING type       (e.g. "krnl")
///     UTF8STRING description
///     OCTET STRING payload  (compressed kernel data)
///     [optional OCTET STRING keybags]
/// }
/// ```
enum IM4PDecoder {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "IM4PDecoder")

    private static let maxDecompressedSize = 128 * 1_024 * 1_024

    static func isIM4P(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        // "IM4P" appears within the first 16 bytes of the DER structure
        let magic: [UInt8] = [0x49, 0x4D, 0x34, 0x50] // "IM4P"
        let header = [UInt8](data.prefix(16))
        return header.indices.dropLast(3).contains { idx in
            header[idx] == magic[0]
            && header[idx + 1] == magic[1]
            && header[idx + 2] == magic[2]
            && header[idx + 3] == magic[3]
        }
    }

    static func extractPayload(from data: Data) -> Data? {
        guard isIM4P(data) else {
            logger.debug("Data is not an IM4P container")
            return nil
        }

        guard let payloadData = extractOctetString(from: data) else {
            logger.warning("Could not extract payload from IM4P container")
            return nil
        }

        logger.info("Extracted IM4P payload: \(payloadData.count) bytes")

        if let decompressed = decompress(payloadData) {
            logger.info("Decompressed kernel: \(decompressed.count) bytes")
            return decompressed
        }

        logger.info("Payload does not appear to be compressed, using raw data")
        return payloadData
    }

    // MARK: - DER parsing

    private static func extractOctetString(from data: Data) -> Data? {
        var offset = 0

        // Skip SEQUENCE tag and length
        guard offset < data.count, data[offset] == 0x30 else { return nil }
        offset += 1
        offset = skipDERLength(data: data, offset: offset)

        // Skip three UTF8STRING fields: "IM4P", type, description
        for _ in 0..<3 {
            guard offset < data.count else { return nil }
            let tag = data[offset]
            guard tag == 0x16 || tag == 0x0C else { return nil }
            offset += 1
            let (length, newOffset) = readDERLength(data: data, offset: offset)
            guard let fieldLength = length else { return nil }
            offset = newOffset + fieldLength
        }

        // Now at the OCTET STRING containing the compressed payload
        guard offset < data.count, data[offset] == 0x04 else { return nil }
        offset += 1
        let (length, newOffset) = readDERLength(data: data, offset: offset)
        guard let payloadLength = length else { return nil }
        offset = newOffset

        guard offset + payloadLength <= data.count else { return nil }
        return data.subdata(in: offset..<(offset + payloadLength))
    }

    private static func skipDERLength(data: Data, offset: Int) -> Int {
        let (_, newOffset) = readDERLength(data: data, offset: offset)
        return newOffset
    }

    private static func readDERLength(data: Data, offset: Int) -> (Int?, Int) {
        guard offset < data.count else { return (nil, offset) }

        let firstByte = data[offset]
        if firstByte & 0x80 == 0 {
            // Short form: length is the byte value itself
            return (Int(firstByte), offset + 1)
        }

        // Long form: lower 7 bits = number of subsequent length bytes
        let numBytes = Int(firstByte & 0x7F)
        guard numBytes > 0, numBytes <= 4, offset + 1 + numBytes <= data.count else {
            return (nil, offset + 1)
        }

        var length = 0
        for idx in 0..<numBytes {
            length = (length << 8) | Int(data[offset + 1 + idx])
        }

        return (length, offset + 1 + numBytes)
    }

    // MARK: - Decompression

    private static func decompress(_ data: Data) -> Data? {
        guard data.count >= 4 else { return nil }

        let magic = data.prefix(4)
        let magicString = String(data: magic, encoding: .ascii) ?? ""

        switch magicString {
        case "bvx2", "bvx-", "bvx1", "bvxn":
            logger.debug("Detected LZFSE compression")
            return decompressWithAlgorithm(data, algorithm: COMPRESSION_LZFSE)
        default:
            // Check for LZMA/XZ magic: 0xFD "7zXZ"
            if data[0] == 0xFD && data.count >= 6 {
                logger.debug("Detected LZMA/XZ compression")
                return decompressWithAlgorithm(data, algorithm: COMPRESSION_LZMA)
            }
            logger.debug("Unknown compression format: magic=\(magicString)")
            return nil
        }
    }

    private static func decompressWithAlgorithm(
        _ data: Data,
        algorithm: compression_algorithm
    ) -> Data? {
        let estimatedSize = min(data.count * 8, maxDecompressedSize)
        var destinationSize = estimatedSize

        for _ in 0..<3 {
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
            defer { destinationBuffer.deallocate() }

            let decompressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
                guard let baseAddress = sourceBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBuffer, destinationSize,
                    baseAddress.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, algorithm
                )
            }

            if decompressedSize > 0 && decompressedSize < destinationSize {
                return Data(bytes: destinationBuffer, count: decompressedSize)
            }

            destinationSize = min(destinationSize * 2, maxDecompressedSize)
            if destinationSize >= maxDecompressedSize {
                break
            }
        }

        logger.warning("Decompression failed or output exceeded \(maxDecompressedSize) bytes")
        return nil
    }
}
