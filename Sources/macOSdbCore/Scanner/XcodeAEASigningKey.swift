import Foundation
import Security

/// Reads the public key an Xcode `.aea` archive names for its own signature.
///
/// Xcode archives use AEA profile 0: signed, not encrypted. `aa` still refuses
/// to open one without the signer's public key, which the archive carries as
/// the first certificate of a PEM chain in its auth data. The key is taken as
/// given, so it lets the archive be read but does not authenticate it.
enum XcodeAEASigningKey {
    static let certificateChainField = "com.apple.ias.signature.certificate-chain"
    static let maxAuthDataBytes = 1 * 1_024 * 1_024
    private static let headerBytes = 12

    /// The hex-encoded X9.63 P-256 public key that `aa -sign-pub-value hex:` expects.
    static func hexPublicKey(ofArchiveAt url: URL) throws -> String {
        let prefix: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            prefix = try handle.read(upToCount: headerBytes + maxAuthDataBytes) ?? Data()
        } catch {
            throw failure("could not read the archive header (\(error.localizedDescription))")
        }
        return try hexPublicKey(fromArchivePrefix: prefix)
    }

    static func hexPublicKey(fromArchivePrefix prefix: Data) throws -> String {
        let bytes = [UInt8](prefix)
        guard bytes.count >= headerBytes, bytes[0..<4].elementsEqual("AEA1".utf8) else {
            throw failure("not an Apple Encrypted Archive")
        }
        let profile = littleEndian(bytes[4..<7])
        guard profile == 0 else {
            throw failure("unsupported AEA profile \(profile); Xcode archives are signed, not encrypted")
        }
        let authDataSize = littleEndian(bytes[8..<12])
        guard authDataSize > 0, authDataSize <= maxAuthDataBytes else {
            throw failure("AEA auth data is missing or too large")
        }
        guard authDataSize <= bytes.count - headerBytes else {
            throw failure("AEA auth data is truncated")
        }
        let chain = try certificateChain(inAuthData: bytes[headerBytes..<(headerBytes + authDataSize)])
        return try hexPublicKey(ofFirstCertificateIn: chain)
    }

    private static func certificateChain(inAuthData authData: ArraySlice<UInt8>) throws -> String {
        var remaining = authData
        while remaining.count >= 4 {
            let fieldSize = littleEndian(remaining.prefix(4))
            guard fieldSize > 4, fieldSize <= remaining.count else { break }
            let payload = remaining.dropFirst(4).prefix(fieldSize - 4)
            if let separator = payload.firstIndex(of: 0),
               payload[..<separator].elementsEqual(certificateChainField.utf8),
               let chain = String(bytes: payload[(separator + 1)...], encoding: .utf8) {
                return chain
            }
            remaining = remaining.dropFirst(fieldSize)
        }
        throw failure("the archive names no signing certificate")
    }

    private static func hexPublicKey(ofFirstCertificateIn chain: String) throws -> String {
        guard let begin = chain.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = chain.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<chain.endIndex),
              let der = Data(
                  base64Encoded: String(chain[begin.upperBound..<end.lowerBound]),
                  options: .ignoreUnknownCharacters
              ),
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let key = SecCertificateCopyKey(certificate),
              let representation = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              representation.count == 65,
              representation.first == 0x04 else {
            throw failure("the archive's signing certificate has no P-256 public key")
        }
        return representation.map { String(format: "%02x", $0) }.joined()
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    private static func failure(_ reason: String) -> ScannerError {
        .xcodeAEAExtractionFailed(reason: reason)
    }
}
