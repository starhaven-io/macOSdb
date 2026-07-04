import Foundation
import Testing

@testable import macOSdbCore

@Suite("AEA decryptor tests")
struct AEADecryptorTests {

    @Test("WKMS URLs are restricted to HTTPS Apple hosts")
    func wkmsURLAllowlist() throws {
        #expect(AEADecryptor.isAllowedWKMSURL(URL(string: "https://gdmf.apple.com/key.pem")!))
        #expect(AEADecryptor.isAllowedWKMSURL(URL(string: "https://updates.cdn-apple.com/key.pem")!))

        #expect(!AEADecryptor.isAllowedWKMSURL(URL(string: "http://gdmf.apple.com/key.pem")!))
        #expect(!AEADecryptor.isAllowedWKMSURL(URL(string: "https://apple.com.evil.example/key.pem")!))
        #expect(!AEADecryptor.isAllowedWKMSURL(URL(string: "https://127.0.0.1/key.pem")!))
        #expect(!AEADecryptor.isAllowedWKMSURL(URL(string: "https://user:pass@gdmf.apple.com/key.pem")!))
    }

    @Test("Malformed auth fields do not hide later WKMS fields")
    func malformedAuthFieldsDoNotHideWKMSFields() async throws {
        var authBlob = Data()
        authBlob.append(malformedField(size: 0))
        authBlob.append(malformedField(size: 1_024))
        authBlob.append(authField(key: "com.apple.wkms.fcs-response", value: "{}"))
        authBlob.append(authField(key: "com.apple.wkms.fcs-key-url", value: "https://gdmf.apple.com/key.pem"))
        let decryptor = AEADecryptor()

        do {
            _ = try await decryptor.deriveKeyOnly(from: aeaData(authBlob: authBlob))
            Issue.record("Expected malformed fcs-response to throw")
        } catch ScannerError.aeaDecryptionFailed(let reason) {
            #expect(reason == "Invalid fcs-response JSON format")
        } catch {
            Issue.record("Expected AEA decryption failure, got \(error)")
        }
    }

    private func aeaData(authBlob: Data) -> Data {
        var data = Data([0x41, 0x45, 0x41, 0x31, 0x01, 0x00, 0x00, 0x00])
        data.append(littleEndian(UInt32(authBlob.count)))
        data.append(authBlob)
        return data
    }

    private func authField(key: String, value: String) -> Data {
        var payload = Data(key.utf8)
        payload.append(0)
        payload.append(contentsOf: value.utf8)
        return field(payload: payload)
    }

    private func malformedField(size: UInt32) -> Data {
        littleEndian(size)
    }

    private func field(payload: Data) -> Data {
        var data = littleEndian(UInt32(payload.count + 4))
        data.append(payload)
        return data
    }

    private func littleEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }
}
