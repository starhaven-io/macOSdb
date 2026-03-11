import Foundation
import Testing

@testable import macOSdbKit

@Suite("Model decoding tests")
struct ModelTests { // swiftlint:disable:this type_body_length

    // MARK: - ReleaseIndexEntry

    @Test("Decode release index from JSON")
    func decodeReleaseIndex() throws {
        let json = Data("""
        [
          {
            "osVersion": "15.6.1",
            "buildNumber": "24G90",
            "releaseName": "Sequoia",
            "releaseDate": "2025-07-07",
            "dataFile": "releases/15/macOS-15.6.1-24G90.json"
          }
        ]
        """.utf8)

        let entries = try JSONDecoder().decode([ReleaseIndexEntry].self, from: json)
        #expect(entries.count == 1)
        #expect(entries[0].osVersion == "15.6.1")
        #expect(entries[0].buildNumber == "24G90")
        #expect(entries[0].releaseName == "Sequoia")
        #expect(entries[0].dataFile == "releases/15/macOS-15.6.1-24G90.json")
    }

    // MARK: - Release

    @Test("Decode release from fixture JSON")
    func decodeRelease() throws {
        let url = Bundle.module.url(
            forResource: "macOS-15.6.1-24G90", withExtension: "json", subdirectory: "Fixtures"
        )!
        let data = try Data(contentsOf: url)
        let release = try JSONDecoder().decode(Release.self, from: data)

        #expect(release.osVersion == "15.6.1")
        #expect(release.buildNumber == "24G90")
        #expect(release.releaseName == "Sequoia")
        #expect(release.majorVersion == 15)
        #expect(release.minorVersion == 6)
        #expect(release.patchVersion == 1)
        #expect(!release.components.isEmpty)
        #expect(!release.kernels.isEmpty)
        #expect(release.scannerVersion == "1.0.0")

        // Verify deviceChips decoded — T6041 kernel has mixed M4 Pro/Max
        let t6041Kernel = release.kernels.first { $0.arch == "ARM64_T6041" }
        #expect(t6041Kernel != nil)
        #expect(t6041Kernel?.chip == "M4 Max")
        #expect(t6041Kernel?.deviceChips?.contains { $0.chip == "M4 Pro" } == true)
        #expect(t6041Kernel?.deviceChips?.contains { $0.chip == "M4 Max" } == true)

        // Verify supportedChips resolves per-device chips
        let chips = release.supportedChips
        #expect(chips.contains(.m4Pro))
        #expect(chips.contains(.m4Max))
        #expect(chips.contains(.m1Pro))
        #expect(chips.contains(.m1Max))
        #expect(chips.contains(.m1Ultra))
    }

    @Test("Release version parsing")
    func releaseVersionParsing() {
        let release = Release(osVersion: "14.6.1", buildNumber: "23G93", releaseName: "Sonoma")
        #expect(release.majorVersion == 14)
        #expect(release.minorVersion == 6)
        #expect(release.patchVersion == 1)
    }

    @Test("Release version parsing with single component")
    func releaseVersionParsingSingle() {
        let release = Release(osVersion: "15", buildNumber: "24A", releaseName: "Sequoia")
        #expect(release.majorVersion == 15)
        #expect(release.minorVersion == 0)
        #expect(release.patchVersion == 0)
    }

    @Test("Release displayName")
    func releaseDisplayName() {
        let release = Release(osVersion: "15.6.1", buildNumber: "24G90", releaseName: "Sequoia")
        #expect(release.displayName == "macOS 15.6.1 Sequoia")
    }

    @Test("Release sorting — newer versions sort higher")
    func releaseSorting() {
        let older = Release(osVersion: "14.6.1", buildNumber: "23G93", releaseName: "Sonoma")
        let newer = Release(osVersion: "15.6.1", buildNumber: "24G90", releaseName: "Sequoia")
        #expect(older < newer)
    }

    @Test("Release component lookup by name")
    func releaseComponentLookup() {
        let release = Release(
            osVersion: "15.6.1",
            buildNumber: "24G90",
            releaseName: "Sequoia",
            components: [
                Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                Component(name: "OpenSSH", version: "9.9p2", path: "/usr/bin/ssh")
            ]
        )

        #expect(release.component(named: "curl")?.version == "8.7.1")
        #expect(release.component(named: "CURL")?.version == "8.7.1")
        #expect(release.component(named: "openssh")?.version == "9.9p2")
        #expect(release.component(named: "nonexistent") == nil)
    }

    // MARK: - Component

    @Test("Component identity is name + path")
    func componentIdentity() {
        let comp = Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
        #expect(comp.id == "curl:/usr/bin/curl")
    }

    @Test("Component displayVersion for normal component")
    func componentDisplayVersionNormal() {
        let comp = Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
        #expect(comp.displayVersion == "8.7.1")
    }

    @Test("Component displayVersion for nil version")
    func componentDisplayVersionNil() {
        let comp = Component(name: "mystery", version: nil, path: "/usr/bin/mystery")
        #expect(comp.displayVersion == "unknown")
    }

    @Test("Component source defaults to filesystem")
    func componentSourceDefault() {
        let comp = Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
        #expect(comp.source == .filesystem)
    }

    @Test("Component with dyldCache source")
    func componentDyldCacheSource() {
        let comp = Component(
            name: "libcurl", version: "8.7.1",
            path: "/usr/lib/libcurl.4.dylib",
            source: .dyldCache
        )
        #expect(comp.source == .dyldCache)
    }

    @Test("Component JSON round-trip with optional version")
    func componentRoundTripNilVersion() throws {
        let comp = Component(name: "mystery", version: nil, path: "/usr/bin/mystery")
        let data = try JSONEncoder().encode(comp)
        let decoded = try JSONDecoder().decode(Component.self, from: data)
        #expect(decoded.name == "mystery")
        #expect(decoded.version == nil)
    }

    // MARK: - KernelInfo

    @Test("Decode kernel info with devices")
    func decodeKernelInfo() throws {
        let json = Data("""
        {
          "file": "kernelcache.release.Mac16,1_2_3",
          "darwinVersion": "24.6.0",
          "xnuVersion": "12377.100.591.501.2",
          "arch": "ARM64_T8132",
          "chip": "M4",
          "devices": ["Mac16,1", "Mac16,2", "Mac16,3"]
        }
        """.utf8)

        let kernel = try JSONDecoder().decode(KernelInfo.self, from: json)
        #expect(kernel.chip == "M4")
        #expect(kernel.darwinVersion == "24.6.0")
        #expect(kernel.xnuVersion == "12377.100.591.501.2")
        #expect(kernel.devices.count == 3)
        #expect(kernel.devices.contains("Mac16,1"))
        #expect(kernel.chipFamily == .m4)
    }

    @Test("Decode kernel info with null xnuVersion")
    func decodeKernelInfoNullXNU() throws {
        let json = Data("""
        {
          "file": "kernelcache.release.Mac16,1",
          "darwinVersion": "24.6.0",
          "arch": "ARM64_T8132",
          "chip": "M4",
          "devices": ["Mac16,1"]
        }
        """.utf8)

        let kernel = try JSONDecoder().decode(KernelInfo.self, from: json)
        #expect(kernel.xnuVersion == nil)
    }

    @Test("Decode kernel info with deviceChips")
    func decodeKernelInfoWithDeviceChips() throws {
        let json = Data("""
        {
          "file": "kernelcache.release.Mac16,5_6_7_8_9_11",
          "darwinVersion": "24.6.0",
          "arch": "ARM64_T6041",
          "chip": "M4 Max",
          "devices": ["Mac16,5", "Mac16,7"],
          "deviceChips": [
            { "device": "Mac16,5", "chip": "M4 Max" },
            { "device": "Mac16,7", "chip": "M4 Pro" }
          ]
        }
        """.utf8)

        let kernel = try JSONDecoder().decode(KernelInfo.self, from: json)
        #expect(kernel.deviceChips?.count == 2)
        #expect(kernel.deviceChips?[0].device == "Mac16,5")
        #expect(kernel.deviceChips?[0].chip == "M4 Max")
        #expect(kernel.deviceChips?[1].chip == "M4 Pro")
    }

    @Test("Decode kernel info without deviceChips — backward compat")
    func decodeKernelInfoBackwardCompat() throws {
        let json = Data("""
        {
          "file": "kernelcache.release.Mac16,1",
          "darwinVersion": "24.6.0",
          "arch": "ARM64_T8132",
          "chip": "M4",
          "devices": ["Mac16,1"]
        }
        """.utf8)

        let kernel = try JSONDecoder().decode(KernelInfo.self, from: json)
        #expect(kernel.deviceChips == nil)
        #expect(kernel.resolvedChipFamilies == [.m4])
    }

    @Test("resolvedChipFamilies uses deviceChips when present")
    func resolvedChipFamiliesFromDeviceChips() {
        let kernel = KernelInfo(
            file: "kernelcache.release.Mac16,5_7",
            darwinVersion: "24.6.0",
            arch: "ARM64_T6041",
            chip: "M4 Max",
            devices: ["Mac16,5", "Mac16,7"],
            deviceChips: [
                DeviceChip(device: "Mac16,5", chip: "M4 Max"),
                DeviceChip(device: "Mac16,7", chip: "M4 Pro")
            ]
        )

        let families = kernel.resolvedChipFamilies
        #expect(families.contains(.m4Max))
        #expect(families.contains(.m4Pro))
        #expect(families.count == 2)
    }

    @Test("resolvedChipFamilies falls back to kernel chip when no deviceChips")
    func resolvedChipFamiliesFallback() {
        let kernel = KernelInfo(
            file: "kernelcache.release.Mac16,1",
            darwinVersion: "24.6.0",
            arch: "ARM64_T8132",
            chip: "M4",
            devices: ["Mac16,1"]
        )

        #expect(kernel.resolvedChipFamilies == [.m4])
    }

    // MARK: - ChipFamily

    @Test("ChipFamily from arch suffix")
    func chipFamilyFromArch() {
        #expect(ChipFamily.from(archSuffix: "T8103") == .m1)
        #expect(ChipFamily.from(archSuffix: "T8101") == .m1)
        #expect(ChipFamily.from(archSuffix: "T8110") == .m2)
        #expect(ChipFamily.from(archSuffix: "T8112") == .m2)
        #expect(ChipFamily.from(archSuffix: "T6040") == .m4Pro)
        #expect(ChipFamily.from(archSuffix: "T6041") == .m4Max)
        #expect(ChipFamily.from(archSuffix: "T6032") == .m3Ultra)
        #expect(ChipFamily.from(archSuffix: "T6034") == .m3Max)
        #expect(ChipFamily.from(archSuffix: "T8142") == .m5)
        #expect(ChipFamily.from(archSuffix: "VMAPPLE") == .virtualMac)
        #expect(ChipFamily.from(archSuffix: "UNKNOWN") == nil)
    }

    @Test("ChipFamily display names")
    func chipFamilyDisplayNames() {
        #expect(ChipFamily.m1.displayName == "M1")
        #expect(ChipFamily.m4Pro.displayName == "M4 Pro")
        #expect(ChipFamily.m3Ultra.displayName == "M3 Ultra")
        #expect(ChipFamily.virtualMac.displayName == "Virtual Mac")
    }

    @Test("ChipFamily from chip name string")
    func chipFamilyFromName() {
        #expect(ChipFamily.from(chipName: "M4") == .m4)
        #expect(ChipFamily.from(chipName: "M4 Pro") == .m4Pro)
        #expect(ChipFamily.from(chipName: "Virtual Mac") == .virtualMac)
        #expect(ChipFamily.from(chipName: "M99") == nil)
    }

    @Test("ChipFamily generation and tier")
    func chipFamilyGenerationAndTier() {
        #expect(ChipFamily.m3Pro.generation == 3)
        #expect(ChipFamily.m3Pro.tier == .pro)
        #expect(ChipFamily.m4Ultra.generation == 4)
        #expect(ChipFamily.m4Ultra.tier == .ultra)
    }

    // MARK: - BuildNumber

    @Test("Beta detection from build number")
    func buildNumberBetaDetection() {
        // Release builds end with a digit
        #expect(BuildNumber.isBeta("24G90") == false)
        #expect(BuildNumber.isBeta("23G93") == false)
        #expect(BuildNumber.isBeta("24A344") == false)

        // Beta builds end with a lowercase letter
        #expect(BuildNumber.isBeta("25E5207k") == true)
        #expect(BuildNumber.isBeta("24A5264n") == true)
        #expect(BuildNumber.isBeta("26A5082a") == true)

        // Edge cases
        #expect(BuildNumber.isBeta("") == false)
    }

    // MARK: - MacOSRelease

    @Test("MacOSRelease name lookup")
    func macOSReleaseName() {
        #expect(MacOSRelease.name(forMajorVersion: 11) == "Big Sur")
        #expect(MacOSRelease.name(forMajorVersion: 14) == "Sonoma")
        #expect(MacOSRelease.name(forMajorVersion: 15) == "Sequoia")
        #expect(MacOSRelease.name(forMajorVersion: 26) == "Tahoe")
        #expect(MacOSRelease.name(forMajorVersion: 99) == "macOS 99")
    }

    // MARK: - Release supported chips

    @Test("Release supported chips derived from kernels with deviceChips")
    func releaseSupportedChips() {
        let release = Release(
            osVersion: "15.6.1",
            buildNumber: "24G90",
            releaseName: "Sequoia",
            kernels: [
                KernelInfo(
                    file: "kernelcache.release.Mac16,1",
                    darwinVersion: "24.6.0",
                    arch: "ARM64_T8132", chip: "M4", devices: ["Mac16,1"],
                    deviceChips: [DeviceChip(device: "Mac16,1", chip: "M4")]
                ),
                KernelInfo(
                    file: "kernelcache.release.Mac16,5_7",
                    darwinVersion: "24.6.0",
                    arch: "ARM64_T6041", chip: "M4 Max",
                    devices: ["Mac16,5", "Mac16,7"],
                    deviceChips: [
                        DeviceChip(device: "Mac16,5", chip: "M4 Max"),
                        DeviceChip(device: "Mac16,7", chip: "M4 Pro")
                    ]
                )
            ]
        )

        let chips = release.supportedChips
        #expect(chips.contains(.m4))
        #expect(chips.contains(.m4Max))
        #expect(chips.contains(.m4Pro))
        #expect(chips.count == 3)
        #expect(release.supportedDevices == ["Mac16,1", "Mac16,5", "Mac16,7"])
    }

    @Test("Release supported chips fallback without deviceChips")
    func releaseSupportedChipsFallback() {
        let release = Release(
            osVersion: "15.6.1",
            buildNumber: "24G90",
            releaseName: "Sequoia",
            kernels: [
                KernelInfo(
                    file: "kernelcache.release.Mac16,1",
                    darwinVersion: "24.6.0",
                    arch: "ARM64_T8132", chip: "M4", devices: ["Mac16,1"]
                )
            ]
        )

        #expect(release.supportedChips == [.m4])
    }
}
