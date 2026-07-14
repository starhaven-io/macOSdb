import Foundation
import Testing
import ZIPFoundation

@testable import macOSdbCore

@Suite("IPSW extractor tests")
struct IPSWExtractorTests {
    @Test("Missing IPSW reports its path")
    func missingIPSW() async {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).ipsw")

        do {
            _ = try await IPSWExtractor().extract(ipswPath: path)
            Issue.record("Expected a missing IPSW error")
        } catch ScannerError.ipswNotFound(let reportedPath) {
            #expect(reportedPath == path.path)
        } catch {
            Issue.record("Expected a missing IPSW error, got \(error)")
        }
    }

    @Test("Build manifest selects DMG roles and maps kernels to devices")
    func extractsUsingBuildManifest() async throws {
        let fixture = try IPSWFixture(
            filename: "fixture.ipsw",
            entries: [
                "BuildManifest.plist": try Self.buildManifest(),
                "Firmware/System.dmg": Data("system".utf8),
                "Firmware/Cryptex.dmg": Data("cryptex".utf8),
                "Firmware/kernelcache.release.mac16x": Data("kernel-a".utf8),
                "Firmware/kernelcache.release.mac15x": Data("kernel-b".utf8)
            ]
        )
        defer { fixture.cleanup() }

        let extractor = IPSWExtractor()
        let result = try await extractor.extract(ipswPath: fixture.archiveURL)
        defer { try? FileManager.default.removeItem(at: result.workDirectory) }

        #expect(result.osVersion == "15.6.1")
        #expect(result.buildNumber == "24G90")
        #expect(result.systemDMG.lastPathComponent == "System.dmg")
        #expect(result.cryptexDMG?.lastPathComponent == "Cryptex.dmg")
        #expect(result.kernelcaches.map(\.lastPathComponent) == [
            "kernelcache.release.mac15x",
            "kernelcache.release.mac16x"
        ])
        #expect(result.kernelDeviceMap["kernelcache.release.mac16x"] == ["Mac16,1", "Mac16,2"])
        #expect(try Data(contentsOf: result.systemDMG) == Data("system".utf8))
        let cryptexData = try result.cryptexDMG.map { try Data(contentsOf: $0) }
        #expect(cryptexData == Data("cryptex".utf8))
    }

    @Test("Restore plist supplies metadata when a manifest is absent")
    func extractsUsingRestorePlist() async throws {
        let restore = try PropertyListSerialization.data(
            fromPropertyList: [
                "ProductVersion": "14.6.1",
                "ProductBuildVersion": "23G93"
            ],
            format: .xml,
            options: 0
        )
        let fixture = try IPSWFixture(
            filename: "restore.ipsw",
            entries: [
                "Restore.plist": restore,
                "small.dmg": Data(repeating: 1, count: 8),
                "largest.dmg": Data(repeating: 2, count: 32)
            ]
        )
        defer { fixture.cleanup() }

        let result = try await IPSWExtractor().extract(ipswPath: fixture.archiveURL)
        defer { try? FileManager.default.removeItem(at: result.workDirectory) }

        #expect(result.osVersion == "14.6.1")
        #expect(result.buildNumber == "23G93")
        #expect(result.systemDMG.lastPathComponent == "largest.dmg")
        #expect(result.cryptexDMG == nil)
    }

    @Test("Filename metadata and largest-DMG fallback work without plists")
    func extractsUsingFilenameFallback() async throws {
        let fixture = try IPSWFixture(
            filename: "UniversalMac_15.7.1_24G231_Restore.ipsw",
            entries: [
                "one.dmg": Data(repeating: 1, count: 4),
                "two.dmg": Data(repeating: 2, count: 16)
            ]
        )
        defer { fixture.cleanup() }

        let result = try await IPSWExtractor().extract(ipswPath: fixture.archiveURL)
        defer { try? FileManager.default.removeItem(at: result.workDirectory) }

        #expect(result.osVersion == "15.7.1")
        #expect(result.buildNumber == "24G231")
        #expect(result.systemDMG.lastPathComponent == "two.dmg")
    }

    @Test("Missing metadata rejects an otherwise readable archive")
    func rejectsMissingMetadata() async throws {
        let fixture = try IPSWFixture(
            filename: "unknown.ipsw",
            entries: ["System.dmg": Data("system".utf8)]
        )
        defer { fixture.cleanup() }

        do {
            _ = try await IPSWExtractor().extract(ipswPath: fixture.archiveURL)
            Issue.record("Expected metadata extraction to fail")
        } catch ScannerError.metadataExtractionFailed(let reason) {
            #expect(reason.contains("Could not determine OS version"))
        } catch {
            Issue.record("Expected a metadata extraction error, got \(error)")
        }
    }

    @Test("An archive without a DMG is rejected")
    func rejectsMissingDMG() async throws {
        let fixture = try IPSWFixture(
            filename: "UniversalMac_15.7_24G200_Restore.ipsw",
            entries: ["kernelcache.release.test": Data("kernel".utf8)]
        )
        defer { fixture.cleanup() }

        do {
            _ = try await IPSWExtractor().extract(ipswPath: fixture.archiveURL)
            Issue.record("Expected the missing DMG to fail")
        } catch ScannerError.systemDMGNotFound {
            // Expected.
        } catch {
            Issue.record("Expected a missing DMG error, got \(error)")
        }
    }

    @Test("AEA header reads are bounded and non-AEA archives return nil")
    func readsBoundedAEAHeader() async throws {
        let header = Data((0..<65_536).map { UInt8($0 % 251) })
        let maxBytes = 24_576
        let encryptedFixture = try IPSWFixture(
            filename: "encrypted.ipsw",
            entries: ["Firmware/System.dmg.aea": header]
        )
        defer { encryptedFixture.cleanup() }

        let extractor = IPSWExtractor()
        let captured = try await extractor.readAEAHeader(
            ipswPath: encryptedFixture.archiveURL,
            maxBytes: maxBytes
        )
        #expect(captured == header.prefix(maxBytes))

        let plainFixture = try IPSWFixture(
            filename: "plain.ipsw",
            entries: ["Firmware/System.dmg": Data("plain".utf8)]
        )
        defer { plainFixture.cleanup() }
        #expect(try await extractor.readAEAHeader(ipswPath: plainFixture.archiveURL) == nil)
    }

    private static func buildManifest() throws -> Data {
        let systemManifest: [String: Any] = [
            "OS": ["Info": ["Path": "Firmware/System.dmg", "ProductVersion": "15.6.1"]],
            "Cryptex1,SystemOS": ["Info": ["Path": "Firmware/Cryptex.dmg"]],
            "KernelCache": ["Info": ["Path": "Firmware/kernelcache.release.mac16x"]]
        ]
        let secondManifest: [String: Any] = [
            "KernelCache": ["Info": ["Path": "Firmware/kernelcache.release.mac16x"]]
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "BuildIdentities": [
                    [
                        "Ap,ProductType": "Mac16,2",
                        "Info": ["BuildNumber": "24G90"],
                        "Manifest": systemManifest
                    ],
                    [
                        "Ap,ProductType": "Mac16,1",
                        "Manifest": secondManifest
                    ]
                ]
            ],
            format: .xml,
            options: 0
        )
    }
}

private struct IPSWFixture {
    let directory: URL
    let archiveURL: URL

    init(filename: String, entries: [String: Data]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-ipsw-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        archiveURL = directory.appendingPathComponent(filename)

        let archive = try Archive(url: archiveURL, accessMode: .create)
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<(start + size))
                }
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
