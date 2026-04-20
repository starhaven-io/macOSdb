import Foundation
import Testing

@testable import macOSdbKit

@Suite("DeviceRegistry tests")
struct DeviceRegistryTests {

    // MARK: - Chip lookups

    @Test("Known M1 devices resolve correctly")
    func m1Devices() {
        #expect(DeviceRegistry.chip(for: "MacBookAir10,1") == .m1)
        #expect(DeviceRegistry.chip(for: "MacBookPro17,1") == .m1)
        #expect(DeviceRegistry.chip(for: "Macmini9,1") == .m1)
        #expect(DeviceRegistry.chip(for: "iMac21,1") == .m1)
        #expect(DeviceRegistry.chip(for: "iMac21,2") == .m1)
    }

    @Test("M1 Pro/Max/Ultra devices resolve correctly")
    func m1ProMaxUltra() {
        #expect(DeviceRegistry.chip(for: "MacBookPro18,1") == .m1Pro)
        #expect(DeviceRegistry.chip(for: "MacBookPro18,3") == .m1Pro)
        #expect(DeviceRegistry.chip(for: "MacBookPro18,2") == .m1Max)
        #expect(DeviceRegistry.chip(for: "MacBookPro18,4") == .m1Max)
        #expect(DeviceRegistry.chip(for: "Mac13,1") == .m1Max)
        #expect(DeviceRegistry.chip(for: "Mac13,2") == .m1Ultra)
    }

    @Test("M2 family devices resolve correctly")
    func m2Family() {
        #expect(DeviceRegistry.chip(for: "Mac14,2") == .m2)
        #expect(DeviceRegistry.chip(for: "Mac14,7") == .m2)
        #expect(DeviceRegistry.chip(for: "Mac14,9") == .m2Pro)
        #expect(DeviceRegistry.chip(for: "Mac14,5") == .m2Max)
        #expect(DeviceRegistry.chip(for: "Mac14,14") == .m2Ultra)
    }

    @Test("M4 Pro vs Max disambiguation — the key fix")
    func m4ProMaxDisambiguation() {
        // These are all in the T6041 (M4 Max) kernel but have different actual chips
        #expect(DeviceRegistry.chip(for: "Mac16,7") == .m4Pro)
        #expect(DeviceRegistry.chip(for: "Mac16,8") == .m4Pro)
        #expect(DeviceRegistry.chip(for: "Mac16,11") == .m4Pro)
        #expect(DeviceRegistry.chip(for: "Mac16,5") == .m4Max)
        #expect(DeviceRegistry.chip(for: "Mac16,6") == .m4Max)
        #expect(DeviceRegistry.chip(for: "Mac16,9") == .m4Max)
    }

    @Test("M5 MacBook Pro resolves correctly")
    func m5Family() {
        #expect(DeviceRegistry.chip(for: "Mac17,2") == .m5)
    }

    @Test("M3 Max vs Ultra disambiguation")
    func m3MaxUltraDisambiguation() {
        // Mac15,14 is in the T6031 (M3 Max) kernel but is actually M3 Ultra
        #expect(DeviceRegistry.chip(for: "Mac15,8") == .m3Max)
        #expect(DeviceRegistry.chip(for: "Mac15,14") == .m3Ultra)
    }

    @Test("Virtual Mac resolves correctly")
    func virtualMac() {
        #expect(DeviceRegistry.chip(for: "VirtualMac2,1") == .virtualMac)
    }

    @Test("Unknown model returns nil")
    func unknownModel() {
        #expect(DeviceRegistry.chip(for: "Mac99,1") == nil)
        #expect(DeviceRegistry.chip(for: "iPhone15,1") == nil)
    }

    // MARK: - Device info

    @Test("Full device info includes marketing name")
    func deviceInfo() {
        let info = DeviceRegistry.info(for: "Mac16,1")
        #expect(info?.chip == .m4)
        #expect(info?.marketingName == "MacBook Pro (14-inch, M4, Late 2024)")
    }

    // MARK: - Coverage

    @Test("All devices have valid chip families")
    func allDevicesValid() {
        for (model, info) in DeviceRegistry.allDevices {
            #expect(info.model == model, "Model key mismatch for \(model)")
            #expect(!info.marketingName.isEmpty, "Missing marketing name for \(model)")
        }
    }
}
