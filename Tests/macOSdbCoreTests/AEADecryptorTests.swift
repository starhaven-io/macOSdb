import CryptoKit
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

    @Test("Header validation rejects malformed AEA data")
    func rejectsMalformedHeaders() async {
        let decryptor = AEADecryptor()
        let invalidHeaders = [
            Data(),
            Data([0x41, 0x45, 0x41]),
            header(magic: [0x42, 0x45, 0x41, 0x31], profile: 1, authSize: 4),
            header(profile: 2, authSize: 4),
            header(profile: 1, authSize: 0),
            header(profile: 1, authSize: 1_048_577),
            header(profile: 1, authSize: 4)
        ]

        for data in invalidHeaders {
            #expect(await decryptor.parseAuthData(from: data).isEmpty)
        }
    }

    @Test("Parses valid AEA auth fields")
    func parsesValidAuthFields() async {
        let authBlob = authField(key: "first", value: "one")
            + authField(key: "second", value: "two")

        let fields = await AEADecryptor().parseAuthData(from: aeaData(authBlob: authBlob))

        #expect(fields == ["first": "one", "second": "two"])
    }

    @Test("Parses AEA auth fields from a Data slice")
    func parsesAuthFieldsFromSlice() async {
        let authBlob = authField(key: "sliced", value: "value")
        var prefixed = Data(repeating: 0xFF, count: 8)
        prefixed.append(aeaData(authBlob: authBlob))
        let slice = prefixed.dropFirst(8)

        #expect(slice.startIndex == 8)
        #expect(await AEADecryptor().parseAuthData(from: slice) == ["sliced": "value"])
    }

    @Test("Key derivation reports missing WKMS fields")
    func reportsMissingWKMSFields() async {
        let decryptor = AEADecryptor()

        await expectDecryptionFailure(
            decryptor,
            data: aeaData(authBlob: authField(key: "unrelated", value: "value")),
            reason: "No fcs-response field in AEA auth data"
        )
        await expectDecryptionFailure(
            decryptor,
            data: aeaData(authBlob: authField(key: "com.apple.wkms.fcs-response", value: "{}")),
            reason: "No fcs-key-url field in AEA auth data"
        )
    }

    @Test("A cached private key avoids a WKMS fetch before rejecting malformed HPKE data")
    func cachedPrivateKeyAvoidsNetwork() async throws {
        let fcs = try JSONSerialization.data(withJSONObject: [
            "enc-request": Data([0x00]).base64EncodedString(),
            "wrapped-key": Data([0x00]).base64EncodedString()
        ])
        let fcsJSON = try #require(String(data: fcs, encoding: .utf8))
        let authBlob = authField(key: "com.apple.wkms.fcs-response", value: fcsJSON)
            + authField(key: "com.apple.wkms.fcs-key-url", value: "https://gdmf.apple.com/key.pem")
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-invalid-hpke-\(UUID().uuidString).aea")
        try aeaData(authBlob: authBlob).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let pem = P256.KeyAgreement.PrivateKey().pemRepresentation
        await #expect(throws: (any Error).self) {
            _ = try await AEADecryptor().decrypt(aeaPath: path, privateKeyPEM: pem)
        }
    }

    @Test("AEA detection follows the archive extension")
    func detectsAEAExtension() {
        #expect(AEADecryptor.isAEA(URL(fileURLWithPath: "/tmp/System.dmg.aea")))
        #expect(!AEADecryptor.isAEA(URL(fileURLWithPath: "/tmp/System.dmg")))
    }

    @Test("File parsing distinguishes a short header from truncated auth data")
    func reportsFileBoundaryErrors() async throws {
        let shortHeader = try writeAEAFile(Data([0x41, 0x45, 0x41]))
        let truncatedAuth = try writeAEAFile(header(profile: 1, authSize: 4))
        defer {
            try? FileManager.default.removeItem(at: shortHeader)
            try? FileManager.default.removeItem(at: truncatedAuth)
        }

        await expectFileDecryptionFailure(shortHeader, reason: "Could not read AEA header")
        await expectFileDecryptionFailure(truncatedAuth, reason: "Could not read AEA auth data blob")
    }

    private func aeaData(authBlob: Data) -> Data {
        var data = Data([0x41, 0x45, 0x41, 0x31, 0x01, 0x00, 0x00, 0x00])
        data.append(littleEndian(UInt32(authBlob.count)))
        data.append(authBlob)
        return data
    }

    private func header(
        magic: [UInt8] = [0x41, 0x45, 0x41, 0x31],
        profile: UInt32,
        authSize: UInt32
    ) -> Data {
        var data = Data(magic)
        data.append(contentsOf: [
            UInt8(profile & 0xff),
            UInt8((profile >> 8) & 0xff),
            UInt8((profile >> 16) & 0xff),
            0
        ])
        data.append(littleEndian(authSize))
        return data
    }

    private func expectDecryptionFailure(
        _ decryptor: AEADecryptor,
        data: Data,
        reason: String
    ) async {
        do {
            _ = try await decryptor.deriveKeyOnly(from: data)
            Issue.record("Expected AEA decryption to fail")
        } catch ScannerError.aeaDecryptionFailed(let actualReason) {
            #expect(actualReason == reason)
        } catch {
            Issue.record("Expected AEA decryption failure, got \(error)")
        }
    }

    private func expectFileDecryptionFailure(_ path: URL, reason: String) async {
        do {
            _ = try await AEADecryptor().decrypt(aeaPath: path, privateKeyPEM: "unused")
            Issue.record("Expected AEA decryption to fail")
        } catch ScannerError.aeaDecryptionFailed(let actualReason) {
            #expect(actualReason == reason)
        } catch {
            Issue.record("Expected AEA decryption failure, got \(error)")
        }
    }

    private func writeAEAFile(_ data: Data) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-aea-boundary-\(UUID().uuidString).aea")
        try data.write(to: path)
        return path
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
