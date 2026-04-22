import Foundation
import Testing

@testable import macOSdbKit

@Suite("Kernel parser tests")
struct KernelParserTests {

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
}
