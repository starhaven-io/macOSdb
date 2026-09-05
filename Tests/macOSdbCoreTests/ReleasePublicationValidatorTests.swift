import Foundation
import Testing

@testable import macOSdbCore

@Suite("Release publication validation")
struct ReleasePublicationValidatorTests {
    @Test("A complete macOS release is publishable")
    func acceptsCompleteMacOSRelease() throws {
        try ReleasePublicationValidator.validate(macOSRelease())
    }

    @Test("Missing components and ordinary empty device lists are rejected")
    func rejectsIncompleteMacOSRelease() {
        #expect(throws: ReleasePublicationError.self) {
            try ReleasePublicationValidator.validate(macOSRelease(components: []))
        }
        #expect(throws: ReleasePublicationError.self) {
            try ReleasePublicationValidator.validate(macOSRelease(devices: []))
        }
    }

    @Test("The documented DTK empty-device exception remains publishable")
    func acceptsDTKDeviceException() throws {
        try ReleasePublicationValidator.validate(macOSRelease(chip: "A12Z (DTK)", devices: []))
    }

    @Test("A complete Xcode release is publishable")
    func acceptsCompleteXcodeRelease() throws {
        try ReleasePublicationValidator.validate(xcodeRelease())
        try ReleasePublicationValidator.validate(
            xcodeRelease(osVersion: "26.0", xipFile: "Xcode_26_Universal.xip")
        )
    }

    @Test("Publication binds product names and source filenames to release identity")
    func rejectsMismatchedProductIdentity() {
        let macOS = macOSRelease()
        let wrongMacOSName = Release(
            osVersion: macOS.osVersion,
            buildNumber: macOS.buildNumber,
            releaseName: "Not Sequoia",
            releaseDate: macOS.releaseDate,
            ipswFile: macOS.ipswFile,
            ipswURL: macOS.ipswURL,
            kernels: macOS.kernels,
            components: macOS.components
        )
        #expect(throws: ReleasePublicationError.self) {
            try ReleasePublicationValidator.validate(wrongMacOSName)
        }
        #expect(throws: ReleasePublicationError.self) {
            try ReleasePublicationValidator.validate(
                xcodeRelease(osVersion: "26.1", xipFile: "Xcode_26.2.xip")
            )
        }
    }

    @Test("Xcode publication requires the dynamically discovered Python component")
    func requiresPythonComponent() {
        let release = xcodeRelease()
        let withoutPython = Release(
            productType: release.productType,
            osVersion: release.osVersion,
            buildNumber: release.buildNumber,
            releaseName: release.releaseName,
            releaseDate: release.releaseDate,
            xipFile: release.xipFile,
            xipURL: release.xipURL,
            components: release.components.filter { $0.name != "Python" },
            sdks: release.sdks,
            minimumOSVersion: release.minimumOSVersion
        )
        #expect(throws: ReleasePublicationError.self) {
            try ReleasePublicationValidator.validate(withoutPython)
        }
    }

    @Test("Xcode publication requires complete SDK metadata")
    func rejectsIncompleteXcodeSDK() {
        #expect(throws: ReleasePublicationError.self) {
            try ReleasePublicationValidator.validate(xcodeRelease(sdks: []))
        }
    }

    private func macOSRelease(
        components: [Component]? = nil,
        chip: String = "M4",
        devices: [String] = ["Mac16,1"]
    ) -> Release {
        let definitions = filesystemComponents + dyldCacheComponents
        let resolvedComponents = components ?? definitions.map {
            let path = $0.path.hasPrefix("/") ? $0.path : "/\($0.path)"
            return Component(name: $0.name, version: "1.0", path: path, source: $0.source)
        }
        return Release(
            osVersion: "15.0",
            buildNumber: "24A335",
            releaseName: "Sequoia",
            releaseDate: "2024-09-16",
            ipswFile: "UniversalMac_15.0_24A335_Restore.ipsw",
            ipswURL: "https://updates.cdn-apple.com/UniversalMac_15.0_24A335_Restore.ipsw",
            kernels: [
                KernelInfo(
                    file: "kernelcache.release.Mac16,1",
                    darwinVersion: "24.0.0",
                    xnuVersion: "11215.1.10",
                    arch: "ARM64_T8132",
                    chip: chip,
                    devices: devices
                )
            ],
            components: resolvedComponents
        )
    }

    private func xcodeRelease(
        osVersion: String = "26.1",
        xipFile: String = "Xcode_26.1.xip",
        sdks: [SDKInfo]? = nil
    ) -> Release {
        let definitions = toolchainComponents + developerComponents + frameworkComponents
        var components = definitions.map {
            let path = $0.path.hasPrefix("/") ? $0.path : "/\($0.path)"
            return Component(name: $0.name, version: "1.0", path: path, source: $0.source)
        }
        components.append(Component(
            name: "Python",
            version: "3.12.0",
            path: "/Library/Frameworks/Python3.framework/Versions/3.12/lib/libpython3.12.dylib",
            source: .filesystem
        ))
        components += sdkComponents.map {
            Component(name: $0.name, version: "1.0", path: "/\($0.path)", source: .sdk)
        }
        return Release(
            productType: .xcode,
            osVersion: osVersion,
            buildNumber: "17B54",
            releaseName: "Xcode \(osVersion)",
            releaseDate: "2025-11-03",
            xipFile: xipFile,
            xipURL: "https://developer.apple.com/services-account/download?path=/Developer_Tools/\(xipFile)",
            components: components,
            sdks: sdks ?? [SDKInfo(sdkVersion: "26.1", buildVersion: "25B78")],
            minimumOSVersion: "15.6"
        )
    }
}
