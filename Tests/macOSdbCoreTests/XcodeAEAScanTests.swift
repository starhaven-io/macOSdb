import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import macOSdbCore

@Suite("Xcode AEA scan tests")
struct XcodeAEAScanTests {
    @Test("Scans an Xcode app packed as a signed AEA archive")
    func scansSignedAEA() async throws {
        let fixture = try ExpandedXcodeFixture()
        defer { fixture.cleanup() }
        let packed = try await SignedAEAFixture(packing: fixture.root, named: "Xcode_26.1_beta.aea")
        defer { packed.cleanup() }

        let messages = Mutex<[String]>([])
        let scanner = XcodeScanner()
        await scanner.recordVerbose { message in messages.withLock { $0.append(message) } }
        let release = try await scanner.scan(archivePath: packed.archive, releaseDate: "2026-08-13")

        #expect(release.resolvedProductType == .xcode)
        #expect(release.osVersion == "26.1")
        #expect(release.buildNumber == "17B123")
        #expect(release.xipFile == "Xcode_26.1_beta.aea")
        #expect(release.minimumOSVersion == "15.0")
        #expect(release.sdks == [SDKInfo(sdkVersion: "26.1", buildVersion: "25B123")])
        #expect(release.component(named: "Swift")?.version == "6.2.1")
        #expect(release.component(named: "libcurl")?.version == "8.10.1")
        try expectWorkspaceRemoved(messages.withLock { $0 }, archiveName: "Xcode_26.1_beta.aea")
    }

    @Test("An archive signed with a key other than the one it names fails extraction")
    func rejectsMismatchedSigningKey() async throws {
        let fixture = try ExpandedXcodeFixture()
        defer { fixture.cleanup() }
        let packed = try await SignedAEAFixture(
            packing: fixture.root,
            named: "mismatched.aea",
            namesSigningKey: false
        )
        defer { packed.cleanup() }

        let messages = Mutex<[String]>([])
        let scanner = XcodeScanner()
        await scanner.recordVerbose { message in messages.withLock { $0.append(message) } }

        do {
            _ = try await scanner.scan(archivePath: packed.archive)
            Issue.record("Expected a mismatched signing key to fail extraction")
        } catch ScannerError.xcodeAEAExtractionFailed(let reason) {
            #expect(!reason.isEmpty)
            #expect(!reason.contains { $0.isNewline })
        } catch {
            Issue.record("Expected an AEA extraction failure, got \(error)")
        }
        try expectWorkspaceRemoved(messages.withLock { $0 }, archiveName: "mismatched.aea")
    }

    @Test("A file that is not an AEA archive fails before extraction and leaves no workspace")
    func rejectsNonArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-xcode-aea-bogus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("bogus.aea")
        try Data("not an archive".utf8).write(to: archive)

        let messages = Mutex<[String]>([])
        let scanner = XcodeScanner()
        await scanner.recordVerbose { message in messages.withLock { $0.append(message) } }

        do {
            _ = try await scanner.scan(archivePath: archive)
            Issue.record("Expected a non-archive to fail")
        } catch ScannerError.xcodeAEAExtractionFailed(let reason) {
            #expect(reason == "not an Apple Encrypted Archive")
        } catch {
            Issue.record("Expected an AEA extraction failure, got \(error)")
        }
        try expectWorkspaceRemoved(messages.withLock { $0 }, archiveName: "bogus.aea")
    }

    private func expectWorkspaceRemoved(_ messages: [String], archiveName: String) throws {
        let prefix = "Extracting \(archiveName) to "
        let workspace = try #require(messages.first { $0.hasPrefix(prefix) }?.dropFirst(prefix.count))
        #expect(!FileManager.default.fileExists(atPath: String(workspace)))
    }
}

/// Packs a directory the way Apple ships Xcode: a raw Apple Archive inside an
/// AEA profile 0 container that is signed with a P-256 key and names that
/// key's certificate in its auth data. The key is generated per fixture.
private struct SignedAEAFixture {
    let archive: URL
    private let directory: URL

    init(packing root: URL, named name: String, namesSigningKey: Bool = true) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-xcode-aea-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        archive = directory.appendingPathComponent(name)

        let signingKey = P256.Signing.PrivateKey()
        let namedKey = namesSigningKey ? signingKey : P256.Signing.PrivateKey()
        let keyFile = directory.appendingPathComponent("named-key.pem")
        let certificate = directory.appendingPathComponent("certificate.pem")
        let payload = directory.appendingPathComponent("payload.aar")
        try Data(namedKey.pemRepresentation.utf8).write(to: keyFile)

        try await Self.run("/usr/bin/openssl", [
            "req", "-x509", "-new", "-key", keyFile.path, "-subj", "/CN=macosdb test", "-days", "1",
            "-out", certificate.path
        ])
        try await Self.run("/usr/bin/aa", ["archive", "-a", "raw", "-d", root.path, "-o", payload.path])
        try await Self.run("/usr/bin/aea", [
            "encrypt", "-profile", "0", "-i", payload.path, "-o", archive.path,
            "-sign-priv-value", "hex:\(signingKey.x963Representation.map { String(format: "%02x", $0) }.joined())",
            "-auth-data-key", XcodeAEASigningKey.certificateChainField, "-auth-data", certificate.path
        ])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: tool),
            arguments: arguments,
            timeout: 60
        )
        let output = String(data: result.stderr, encoding: .utf8) ?? ""
        try #require(result.terminationStatus == 0, "\(tool) failed: \(output)")
    }
}
