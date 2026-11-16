import Foundation
import Testing

@testable import macOSdbCore

@Suite("Xcode AEA signing key tests")
struct XcodeAEASigningKeyTests {
    @Test("Reads the first certificate's P-256 key from a signed archive header")
    func readsLeafKey() throws {
        let chain = XcodeAEAFixture.p256Certificate + XcodeAEAFixture.p384Certificate
        let prefix = XcodeAEAFixture.archivePrefix(fields: [
            ("com.example.other", "ignored"),
            (XcodeAEASigningKey.certificateChainField, chain)
        ])
        #expect(try XcodeAEASigningKey.hexPublicKey(fromArchivePrefix: prefix) == XcodeAEAFixture.p256PublicKeyHex)
    }

    @Test("Reads the key from a file without needing the rest of the archive")
    func readsKeyFromFile() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-aea-key-\(UUID().uuidString).aea")
        defer { try? FileManager.default.removeItem(at: archive) }
        try (XcodeAEAFixture.archivePrefix() + Data(repeating: 0xAB, count: 64)).write(to: archive)

        #expect(try XcodeAEASigningKey.hexPublicKey(ofArchiveAt: archive) == XcodeAEAFixture.p256PublicKeyHex)
    }

    @Test("Rejects headers that are not a signed Xcode archive", arguments: [
        (Data("not an archive".utf8), "not an Apple Encrypted Archive"),
        (XcodeAEAFixture.archivePrefix(magic: "AEA2"), "not an Apple Encrypted Archive"),
        (XcodeAEAFixture.archivePrefix(profile: 1), "unsupported AEA profile 1"),
        (XcodeAEAFixture.archivePrefix(fields: []), "missing or too large"),
        (XcodeAEAFixture.archivePrefix(declaredAuthDataSize: XcodeAEASigningKey.maxAuthDataBytes + 1), "missing or too large"),
        (XcodeAEAFixture.archivePrefix().dropLast(1), "truncated"),
        (XcodeAEAFixture.archivePrefix(fields: [("com.example.other", "value")]), "names no signing certificate"),
        (XcodeAEAFixture.archivePrefix(authData: Data([2, 0, 0, 0, 0, 0, 0, 0])), "names no signing certificate"),
        (XcodeAEAFixture.archivePrefix(authData: Data([0xFF, 0xFF, 0, 0, 0, 0, 0, 0])), "names no signing certificate"),
        (XcodeAEAFixture.archivePrefix(chain: "-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----\n"), "no P-256 public key"),
        (XcodeAEAFixture.archivePrefix(chain: XcodeAEAFixture.p384Certificate), "no P-256 public key")
    ])
    func rejectsUnusableHeaders(prefix: Data, expected: String) {
        do {
            _ = try XcodeAEASigningKey.hexPublicKey(fromArchivePrefix: Data(prefix))
            Issue.record("Expected the header to be rejected")
        } catch ScannerError.xcodeAEAExtractionFailed(let reason) {
            #expect(reason.contains(expected))
        } catch {
            Issue.record("Expected an AEA extraction failure, got \(error)")
        }
    }

    @Test("A missing archive reports that its header could not be read")
    func missingArchive() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-aea-missing-\(UUID().uuidString).aea")
        do {
            _ = try XcodeAEASigningKey.hexPublicKey(ofArchiveAt: missing)
            Issue.record("Expected a missing archive to fail")
        } catch ScannerError.xcodeAEAExtractionFailed(let reason) {
            #expect(reason.contains("could not read the archive header"))
        } catch {
            Issue.record("Expected an AEA extraction failure, got \(error)")
        }
    }
}

/// Builds the leading bytes of an AEA profile 0 archive: magic, profile, auth
/// data size, then key-value auth fields. The certificates are throwaway
/// self-signed fixtures whose private keys were discarded.
enum XcodeAEAFixture {
    static let p256PublicKeyHex =
        "04682534f38aaf048bcd67cd3633a427d75862440078e09e17723a562b0c64f412"
            + "47bbba016a8631412b610313f4d4730901ac667cfad7cb37570b614df7eaff8b"

    static let p256Certificate = pem(fromHexDER: """
        3082012c3081d4020900e34c1d677c5435f9300a06082a8648ce3d040302301f311d301b06035504030c146d61636f73
        646220746573742066697874757265301e170d3236313131343137333832355a170d3336313131313137333832355a30
        1f311d301b06035504030c146d61636f736462207465737420666978747572653059301306072a8648ce3d020106082a
        8648ce3d03010703420004682534f38aaf048bcd67cd3633a427d75862440078e09e17723a562b0c64f41247bbba016a
        8631412b610313f4d4730901ac667cfad7cb37570b614df7eaff8b300a06082a8648ce3d0403020347003044022048e6
        f49c4fea286c302f7b536af4d7926511bd7223119900a159dce74a28a33b02206a682785a6278b7753b612071eb1f590
        6e201d0bcf9a6e9ab0d3ba3dd70c8614
        """)

    static let p384Certificate = pem(fromHexDER: """
        3082016a3081f1020900ca686f6093a4f31a300a06082a8648ce3d040302301f311d301b06035504030c146d61636f73
        646220746573742066697874757265301e170d3236313131343137333832355a170d3336313131313137333832355a30
        1f311d301b06035504030c146d61636f736462207465737420666978747572653076301006072a8648ce3d020106052b
        81040022036200044e6f6dd14018fb9ee5d25e515e8b8e16cda8c32cc73e0548ac6e7c77476818361689ad3c46de36ff
        29d51f113f8ad21453977b9e2e91c4b2057bf5b405152cc26a7753613ca270fb6acb9e0dd83ee4a757ac2977f04d0c6f
        95b633291c42d3e4300a06082a8648ce3d040302036800306502304194390c8a1e0c4d5ccec54d1fcf23b5e1789650b0
        3141b6dc79f4eddeabfd5eedf43fbf3e5313b444ebd2c5e9474824023100b3e094d4006b37a8966c82bfba5f854e7ba4
        fb3b6f0fef589d9f8dbf94d1eda97e39ebf64d5d47b0e3d874f20f2df819
        """)

    private static func pem(fromHexDER hex: String) -> String {
        let digits = Array(hex.filter(\.isHexDigit))
        let der = Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0..<($0 + 2)]), radix: 16) ?? 0 })
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    }

    static func archivePrefix(
        magic: String = "AEA1",
        profile: UInt32 = 0,
        chain: String = p256Certificate,
        declaredAuthDataSize: Int? = nil
    ) -> Data {
        archivePrefix(
            magic: magic,
            profile: profile,
            fields: [(XcodeAEASigningKey.certificateChainField, chain)],
            declaredAuthDataSize: declaredAuthDataSize
        )
    }

    static func archivePrefix(
        magic: String = "AEA1",
        profile: UInt32 = 0,
        fields: [(key: String, value: String)],
        declaredAuthDataSize: Int? = nil
    ) -> Data {
        var authData = Data()
        for field in fields {
            let payload = Data(field.key.utf8) + [0] + Data(field.value.utf8)
            authData += littleEndian(UInt32(payload.count + 4)) + payload
        }
        return archivePrefix(
            magic: magic,
            profile: profile,
            authData: authData,
            declaredAuthDataSize: declaredAuthDataSize
        )
    }

    static func archivePrefix(
        magic: String = "AEA1",
        profile: UInt32 = 0,
        authData: Data,
        declaredAuthDataSize: Int? = nil
    ) -> Data {
        var prefix = Data(magic.utf8)
        prefix += littleEndian(profile).prefix(3) + [0]
        prefix += littleEndian(UInt32(declaredAuthDataSize ?? authData.count))
        return prefix + authData
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
