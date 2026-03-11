import Foundation
import Testing

@testable import macOSdbKit

@Suite("IM4P decoder tests")
struct IM4PDecoderTests {

    @Test("Detects IM4P container from magic bytes")
    func detectIM4P() {
        // Minimal IM4P-like header: SEQUENCE containing "IM4P"
        var bytes: [UInt8] = [
            0x30, 0x20,       // SEQUENCE, length 32
            0x16, 0x04,       // UTF8STRING, length 4
            0x49, 0x4D, 0x34, 0x50  // "IM4P"
        ]
        bytes.append(contentsOf: [UInt8](repeating: 0x00, count: 24))
        #expect(IM4PDecoder.isIM4P(Data(bytes)))
    }

    @Test("Rejects non-IM4P data")
    func rejectNonIM4P() {
        let data = Data("This is not an IM4P container at all".utf8)
        #expect(!IM4PDecoder.isIM4P(data))
    }

    @Test("Rejects data too short to be IM4P")
    func rejectShortData() {
        let data = Data([0x30, 0x04, 0x16, 0x02])
        #expect(!IM4PDecoder.isIM4P(data))
    }

    @Test("Extracts uncompressed payload from synthetic IM4P")
    func extractUncompressedPayload() {
        // Build a valid IM4P DER structure with an uncompressed payload
        let payload = Data("Darwin Kernel Version 20.6.0: test data here".utf8)
        let im4pData = buildIM4P(type: "krnl", description: "test", payload: payload)

        let result = IM4PDecoder.extractPayload(from: im4pData)
        #expect(result != nil)
        #expect(result == payload)
    }

    @Test("Returns nil for truncated IM4P")
    func truncatedIM4P() {
        var bytes: [UInt8] = [
            0x30, 0x84, 0x00, 0x00, 0x01, 0x00, // SEQUENCE, large length
            0x16, 0x04,
            0x49, 0x4D, 0x34, 0x50 // "IM4P"
        ]
        // Truncated — no more data
        bytes.append(contentsOf: [UInt8](repeating: 0x00, count: 4))
        #expect(IM4PDecoder.extractPayload(from: Data(bytes)) == nil)
    }

    @Test("Board codename returns empty devices")
    func parseBoardConfigDevice() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.release.mac13g"
        )
        #expect(devices.isEmpty)
    }

    // MARK: - Helpers

    /// Build a minimal valid IM4P DER structure for testing.
    private func buildIM4P(type: String, description: String, payload: Data) -> Data {
        var result = Data()

        // Build inner content first, then wrap in SEQUENCE
        var inner = Data()

        // UTF8STRING "IM4P"
        inner.append(0x16)
        inner.append(UInt8(4))
        inner.append(contentsOf: "IM4P".utf8)

        // UTF8STRING type
        let typeBytes = Data(type.utf8)
        inner.append(0x16)
        inner.append(UInt8(typeBytes.count))
        inner.append(typeBytes)

        // UTF8STRING description
        let descBytes = Data(description.utf8)
        inner.append(0x16)
        inner.append(UInt8(descBytes.count))
        inner.append(descBytes)

        // OCTET STRING payload
        inner.append(0x04)
        appendDERLength(&inner, length: payload.count)
        inner.append(payload)

        // SEQUENCE wrapper
        result.append(0x30)
        appendDERLength(&result, length: inner.count)
        result.append(inner)

        return result
    }

    private func appendDERLength(_ data: inout Data, length: Int) {
        if length < 128 {
            data.append(UInt8(length))
        } else if length < 256 {
            data.append(0x81)
            data.append(UInt8(length))
        } else if length < 65_536 {
            data.append(0x82)
            data.append(UInt8(length >> 8))
            data.append(UInt8(length & 0xFF))
        } else {
            data.append(0x84)
            data.append(UInt8((length >> 24) & 0xFF))
            data.append(UInt8((length >> 16) & 0xFF))
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
        }
    }
}
