import Foundation
import Testing

@testable import macOSdbCore

@Suite("Kernel parser tests")
struct KernelParserTests {

    @Test("Parse a raw kernelcache file")
    func parseRawKernelcache() async throws {
        let path = try writeKernelcache(
            name: "kernelcache.release.Mac16,1_2",
            data: Data(
                "Darwin Kernel Version 24.6.0: xnu-12377.140.9/RELEASE_ARM64_T8132".utf8
            )
        )
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let kernel = try #require(await KernelParser.parse(kernelcachePath: path))
        #expect(kernel.file == "kernelcache.release.Mac16,1_2")
        #expect(kernel.darwinVersion == "24.6.0")
        #expect(kernel.xnuVersion == "12377.140.9")
        #expect(kernel.arch == "ARM64_T8132")
        #expect(kernel.chip == "M4")
        #expect(kernel.devices == ["Mac16,1", "Mac16,2"])
    }

    @Test("Unreadable and versionless kernelcaches are ignored")
    func ignoresUnreadableAndVersionlessKernelcaches() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-kernelcache-\(UUID().uuidString)")
        #expect(await KernelParser.parse(kernelcachePath: missing) == nil)

        let versionless = try writeKernelcache(
            name: "kernelcache.release.Mac16,1",
            data: Data("not a kernel banner".utf8)
        )
        defer { try? FileManager.default.removeItem(at: versionless.deletingLastPathComponent()) }
        #expect(await KernelParser.parse(kernelcachePath: versionless) == nil)
    }

    @Test("Oversized kernelcaches are rejected before reading")
    func rejectsOversizedKernelcache() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernelcache.release.oversized-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: path.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: path) }

        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: UInt64(KernelParser.maxKernelcacheBytes + 1))
        try handle.close()

        #expect(await KernelParser.parse(kernelcachePath: path) == nil)
    }

    // MARK: - Version scanning

    @Test("scanVersions extracts darwin, xnu, and arch suffix in a single pass")
    func scanVersionsExtractsFields() {
        var bytes = [UInt8](
            "Darwin Kernel Version 24.5.0: xnu-11417.121.6~2/RELEASE_ARM64_T6000".utf8
        )
        bytes.append(0x00)
        let result = KernelParser.scanVersions(in: Data(bytes))
        #expect(result.darwin == "24.5.0")
        #expect(result.xnu == "11417.121.6")
        #expect(result.archSuffix == "T6000")
        #expect(result.isComplete)
    }

    @Test("scanVersions leaves darwin empty when no kernel banner is present")
    func scanVersionsNoBanner() {
        let result = KernelParser.scanVersions(in: Data("nothing useful here".utf8))
        #expect(result.darwin.isEmpty)
        #expect(!result.isComplete)
    }

    @Test("Parse device models from simple filename")
    func parseSimpleDevices() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.release.Mac16,1_2_3_10_12_13"
        )
        #expect(devices == ["Mac16,1", "Mac16,2", "Mac16,3", "Mac16,10", "Mac16,12", "Mac16,13"])
    }

    @Test("Parse device models with multiple families")
    func parseMultipleFamilies() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.release.MacBookAir10,1_MacBookPro17,1_Macmini9,1_iMac21,1_2"
        )
        #expect(devices == [
            "MacBookAir10,1",
            "MacBookPro17,1",
            "Macmini9,1",
            "iMac21,1",
            "iMac21,2"
        ])
    }

    @Test("Parse VirtualMac device")
    func parseVirtualMac() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.release.VirtualMac2,1"
        )
        #expect(devices == ["VirtualMac2,1"])
    }

    @Test("Parse Mac Pro style filename")
    func parseMacPro() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.release.Mac14,5_6_8_9_10_12_13_14"
        )
        #expect(devices == [
            "Mac14,5", "Mac14,6", "Mac14,8", "Mac14,9",
            "Mac14,10", "Mac14,12", "Mac14,13", "Mac14,14"
        ])
    }

    @Test("Board codename filename returns empty devices")
    func parseBoardCodename() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.release.mac13g"
        )
        #expect(devices.isEmpty)
    }

    @Test("Another board codename returns empty devices")
    func parseBoardCodenameJ274() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.release.j274ap"
        )
        #expect(devices.isEmpty)
    }

    @Test("Parse device models from development kernelcache")
    func parseDevelopmentKernelcache() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.development.Mac16,1_2_3"
        )
        #expect(devices == ["Mac16,1", "Mac16,2", "Mac16,3"])
    }

    @Test("Development board codename returns empty devices")
    func parseDevelopmentBoardCodename() {
        let devices = KernelParser.parseDevicesFromFilename(
            "kernelcache.development.mac13g"
        )
        #expect(devices.isEmpty)
    }

    private func writeKernelcache(name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-kernel-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name)
        try data.write(to: path)
        return path
    }
}
