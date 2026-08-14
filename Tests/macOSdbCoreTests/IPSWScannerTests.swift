import Foundation
import Testing

@testable import macOSdbCore

@Suite("IPSW scanner tests")
struct IPSWScannerTests {

    @Test("Assembles beta metadata from an extracted IPSW")
    func assemblesBetaRelease() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extraction = IPSWExtractor.ExtractionResult(
            workDirectory: root,
            kernelcaches: [],
            systemDMG: root.appendingPathComponent("System.dmg"),
            cryptexDMG: nil,
            osVersion: "26.0",
            buildNumber: "25A5279m",
            kernelDeviceMap: [:]
        )
        let kernel = KernelInfo(
            file: "kernelcache.release.Mac16,1",
            darwinVersion: "25.0.0",
            xnuVersion: "12345.1.1",
            arch: "ARM64_T8132",
            chip: "M4",
            devices: ["Mac16,1"]
        )
        let curl = Component(name: "curl", version: "8.10.1", path: "/usr/bin/curl")

        let release = await IPSWScanner().assembleRelease(
            extraction: extraction,
            kernels: [kernel],
            components: [curl],
            sourceFilename: "UniversalMac_26.0_25A5279m_Restore.ipsw",
            releaseDate: "2026-06-10",
            ipswURL: "https://updates.cdn-apple.com/UniversalMac_26.0_25A5279m_Restore.ipsw",
            isBeta: nil,
            betaNumber: 2,
            betaRevision: 3,
            isDeviceSpecific: true
        )

        #expect(release.releaseName == "Tahoe")
        #expect(release.ipswFile == "UniversalMac_26.0_25A5279m_Restore.ipsw")
        #expect(release.isBeta)
        #expect(release.betaNumber == 2)
        #expect(release.betaRevision == 3)
        #expect(release.isDeviceSpecific)
        #expect(release.kernels == [kernel])
        #expect(release.components == [curl])
    }

    @Test("Release candidates override beta metadata during assembly")
    func assemblesReleaseCandidate() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extraction = IPSWExtractor.ExtractionResult(
            workDirectory: root,
            kernelcaches: [],
            systemDMG: root.appendingPathComponent("System.dmg"),
            cryptexDMG: nil,
            osVersion: "27.0",
            buildNumber: "26A5300a",
            kernelDeviceMap: [:]
        )

        let release = await IPSWScanner().assembleRelease(
            extraction: extraction,
            kernels: [],
            components: [],
            sourceFilename: "fixture.ipsw",
            releaseName: "Golden Gate",
            isBeta: true,
            betaNumber: 4,
            isRC: true,
            rcNumber: 2
        )

        #expect(release.releaseName == "Golden Gate")
        #expect(!release.isBeta)
        #expect(release.betaNumber == nil)
        #expect(release.isRC)
        #expect(release.rcNumber == 2)
    }

    @Test("Parses kernels concurrently, applies device mappings, and sorts results")
    func parsesAndResolvesKernels() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let second = try write(
            "Darwin Kernel Version 24.6.0: xnu-12377.140.9/RELEASE_ARM64",
            to: root.appendingPathComponent("kernelcache.release.fixture-b")
        )
        let first = try write(
            "Darwin Kernel Version 24.5.0: xnu-12377.121.3/RELEASE_ARM64",
            to: root.appendingPathComponent("kernelcache.release.fixture-a")
        )

        let kernels = try await IPSWScanner().parseKernels(
            [second, first],
            deviceMap: [
                first.lastPathComponent: ["Mac16,1"],
                second.lastPathComponent: ["Mac16,2"]
            ]
        )

        #expect(kernels.map(\.file) == [first.lastPathComponent, second.lastPathComponent])
        #expect(kernels.map(\.chip) == ["M4", "M4"])
        #expect(kernels.map(\.devices) == [["Mac16,1"], ["Mac16,2"]])
        #expect(kernels.map { $0.deviceChips?.first?.chip } == ["M4", "M4"])
    }

    @Test("Extracts available filesystem components and skips missing or unmatched binaries")
    func extractsFilesystemComponents() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try write("curl 8.10.1", to: root.appendingPathComponent("usr/bin/curl"))
        _ = try write("not an Apache version", to: root.appendingPathComponent("usr/sbin/httpd"))

        let mount = DMGMounter.MountPoint(path: root.path, deviceNode: "/dev/test")
        let components = await IPSWScanner().extractFilesystemComponents(mountPoint: mount)

        #expect(components == [
            Component(name: "curl", version: "8.10.1", path: "/usr/bin/curl", source: .filesystem)
        ])
    }

    @Test("Returns no dyld components when a mounted fixture has no cache")
    func missingDyldCacheReturnsEmpty() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mount = DMGMounter.MountPoint(path: root.path, deviceNode: "/dev/test")
        #expect(await IPSWScanner().extractDyldCacheComponents(mountPoint: mount).isEmpty)
    }

    @Test("Finds canonical and fallback dyld cache locations")
    func findsDyldCaches() throws {
        let canonicalRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        let canonical = try write(
            "cache",
            to: canonicalRoot.appendingPathComponent("System/Library/dyld/dyld_shared_cache_arm64e")
        )
        #expect(findDyldCache(mountPoint: canonicalRoot.path) == canonical)

        let fallbackRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: fallbackRoot) }
        _ = try write(
            "map",
            to: fallbackRoot.appendingPathComponent("System/Library/dyld/dyld_shared_cache_custom.map")
        )
        let fallback = try write(
            "cache",
            to: fallbackRoot.appendingPathComponent("System/Library/dyld/dyld_shared_cache_custom")
        )
        #expect(
            findDyldCache(mountPoint: fallbackRoot.path)?.resolvingSymlinksInPath()
                == fallback.resolvingSymlinksInPath()
        )
        #expect(findDyldCache(mountPoint: "/definitely/missing") == nil)
    }

    @Test("Resolves exact and versioned dylib paths")
    func resolvesDylibPaths() {
        let exact = "/usr/lib/libcurl.4.dylib"
        let versioned = "/usr/lib/libcurl.5.dylib"

        #expect(resolveDylibPath(exact, in: [exact], allPaths: [exact]) == exact)
        #expect(resolveDylibPath(exact, in: [], allPaths: [versioned]) == versioned)
        #expect(resolveDylibPath("/usr/lib/libcurl", in: [], allPaths: [versioned]) == nil)
        #expect(resolveDylibPath(exact, in: [], allPaths: ["/usr/lib/libssl.5.dylib"]) == nil)
    }

    @Test("Cryptex components override system components by name")
    func mergesCryptexComponents() {
        let curl = Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
        let systemSSL = Component(name: "LibreSSL", version: "3.3.6", path: "/usr/bin/openssl")
        let cryptexSSL = Component(name: "LibreSSL", version: "3.3.8", path: "/usr/bin/openssl")

        #expect(merging([curl, systemSSL], overriddenBy: []) == [curl, systemSSL])
        #expect(merging([curl, systemSSL], overriddenBy: [cryptexSSL]) == [curl, cryptexSSL])
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-ipsw-scanner-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ string: String, to path: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: path)
        return path
    }
}
