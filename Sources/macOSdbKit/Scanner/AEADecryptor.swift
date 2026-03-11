import CryptoKit
import Foundation
import OSLog

/// Decrypts Apple Encrypted Archive (AEA) files found in macOS 15+ IPSWs.
///
/// Starting with macOS 15 (Sequoia), system DMGs inside IPSWs are encrypted
/// using AEA profile 1 (HKDF-SHA256 + AES-CTR-HMAC, symmetric key). The key
/// is wrapped via HPKE and can be unwrapped by fetching a private key from
/// Apple's public WKMS (Web Key Management Service).
///
/// Decryption steps:
/// 1. Parse the AEA header to extract auth data fields
/// 2. Fetch the HPKE private key from Apple's WKMS
/// 3. Unwrap the symmetric decryption key using CryptoKit HPKE
/// 4. Shell out to `/usr/bin/aea decrypt` with the derived key
public actor AEADecryptor {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "AEADecryptor")

    public static func isAEA(_ url: URL) -> Bool {
        url.pathExtension == "aea"
    }

    /// Decrypts and removes the `.aea` file, returning the path to the decrypted `.dmg`.
    public func decrypt(aeaPath: URL) async throws -> URL {
        let key = try await deriveKey(from: aeaPath)
        let outputPath = aeaPath.deletingPathExtension()
        try runAEADecrypt(input: aeaPath, output: outputPath, key: key)
        try? FileManager.default.removeItem(at: aeaPath)
        return outputPath
    }

    // MARK: - Key derivation

    private func deriveKey(from aeaPath: URL) async throws -> String {
        let fields = try parseAuthData(from: aeaPath)

        guard let fcsResponseJSON = fields["com.apple.wkms.fcs-response"] else {
            throw ScannerError.aeaDecryptionFailed(reason: "No fcs-response field in AEA auth data")
        }
        guard let keyURLString = fields["com.apple.wkms.fcs-key-url"] else {
            throw ScannerError.aeaDecryptionFailed(reason: "No fcs-key-url field in AEA auth data")
        }

        guard let fcsData = fcsResponseJSON.data(using: .utf8),
              let fcs = try? JSONSerialization.jsonObject(with: fcsData) as? [String: String],
              let encRequestB64 = fcs["enc-request"],
              let wrappedKeyB64 = fcs["wrapped-key"],
              let encRequest = Data(base64Encoded: encRequestB64),
              let wrappedKey = Data(base64Encoded: wrappedKeyB64) else {
            throw ScannerError.aeaDecryptionFailed(reason: "Invalid fcs-response JSON format")
        }

        let pemString = try await fetchPrivateKey(from: keyURLString)
        let privateKey = try P256.KeyAgreement.PrivateKey(pemRepresentation: pemString)

        let ciphersuite = HPKE.Ciphersuite(
            kem: .P256_HKDF_SHA256,
            kdf: .HKDF_SHA256,
            aead: .AES_GCM_256
        )

        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: ciphersuite,
            info: Data(),
            encapsulatedKey: encRequest
        )

        let symmetricKey = try recipient.open(wrappedKey)
        Self.logger.info("Derived AEA decryption key")
        return symmetricKey.base64EncodedString()
    }

    // MARK: - AEA header parsing

    private func parseAuthData(from aeaPath: URL) throws -> [String: String] {
        let fileHandle = try FileHandle(forReadingFrom: aeaPath)
        defer { try? fileHandle.close() }

        guard let header = try fileHandle.read(upToCount: 12), header.count == 12 else {
            throw ScannerError.aeaDecryptionFailed(reason: "Could not read AEA header")
        }

        let headerBytes = [UInt8](header)

        guard headerBytes[0] == 0x41, headerBytes[1] == 0x45,
              headerBytes[2] == 0x41, headerBytes[3] == 0x31 else {
            throw ScannerError.aeaDecryptionFailed(reason: "Invalid AEA magic bytes")
        }

        let profile = UInt32(headerBytes[4])
            | (UInt32(headerBytes[5]) << 8)
            | (UInt32(headerBytes[6]) << 16)
        guard profile == 1 else {
            throw ScannerError.aeaDecryptionFailed(reason: "Unsupported AEA profile: \(profile)")
        }

        let authSize = Int(headerBytes[8])
            | (Int(headerBytes[9]) << 8)
            | (Int(headerBytes[10]) << 16)
            | (Int(headerBytes[11]) << 24)
        guard authSize > 0 else {
            throw ScannerError.aeaDecryptionFailed(reason: "No auth data in AEA file")
        }

        guard let authBlob = try fileHandle.read(upToCount: authSize),
              authBlob.count == authSize else {
            throw ScannerError.aeaDecryptionFailed(reason: "Could not read AEA auth data blob")
        }

        let authBytes = [UInt8](authBlob)
        var fields: [String: String] = [:]
        var offset = 0

        while offset + 4 <= authBytes.count {
            let fieldSize = Int(authBytes[offset])
                | (Int(authBytes[offset + 1]) << 8)
                | (Int(authBytes[offset + 2]) << 16)
                | (Int(authBytes[offset + 3]) << 24)

            guard fieldSize > 4, offset + fieldSize <= authBytes.count else { break }

            let fieldData = authBytes[(offset + 4)..<(offset + fieldSize)]
            if let nullIndex = fieldData.firstIndex(of: 0) {
                let keyData = Data(fieldData[fieldData.startIndex..<nullIndex])
                let valueData = Data(fieldData[(nullIndex + 1)...])
                if let key = String(data: keyData, encoding: .utf8),
                   let value = String(data: valueData, encoding: .utf8) {
                    fields[key] = value
                }
            }

            offset += fieldSize
        }

        return fields
    }

    // MARK: - Network

    private func fetchPrivateKey(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw ScannerError.aeaDecryptionFailed(reason: "Invalid WKMS key URL: \(urlString)")
        }

        Self.logger.info("Fetching decryption key from \(urlString)")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ScannerError.aeaDecryptionFailed(
                reason: "WKMS key fetch failed (HTTP \(status))"
            )
        }

        guard let pem = String(data: data, encoding: .utf8) else {
            throw ScannerError.aeaDecryptionFailed(reason: "Invalid PEM data from WKMS")
        }

        return pem
    }

    // MARK: - Decryption

    private func runAEADecrypt(input: URL, output: URL, key: String) throws {
        Self.logger.info("Decrypting \(input.lastPathComponent)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/aea")
        process.arguments = [
            "decrypt",
            "-i", input.path,
            "-o", output.path,
            "-key-value", "base64:\(key)"
        ]

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? "unknown error"
            throw ScannerError.aeaDecryptionFailed(reason: "aea decrypt failed: \(errorMessage)")
        }
    }
}
