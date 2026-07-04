import Foundation
import Testing

@testable import macOSdbCore

@Suite("ScannerError descriptions")
struct ScannerErrorTests {
    @Test("Descriptions include the relevant context")
    func descriptionsIncludeContext() {
        let cases: [(ScannerError, String)] = [
            (.ipswNotFound(path: "/tmp/a.ipsw"), "IPSW file not found: /tmp/a.ipsw"),
            (.ipswExtractionFailed(reason: "bad zip"), "Failed to extract IPSW: bad zip"),
            (.systemDMGNotFound, "Could not find system DMG inside the IPSW"),
            (.dmgMountFailed(path: "/tmp/System.dmg", reason: "busy"), "Failed to mount DMG /tmp/System.dmg: busy"),
            (.noKernelcachesFound, "No kernelcache files found in the IPSW"),
            (.dyldCacheParseFailed(reason: "truncated"), "Failed to parse dyld shared cache: truncated"),
            (.componentExtractionFailed(name: "curl", reason: "not found"), "Failed to extract curl: not found"),
            (.metadataExtractionFailed(reason: "missing plist"), "Failed to extract IPSW metadata: missing plist"),
            (.aeaDecryptionFailed(reason: "no key"), "AEA decryption failed: no key"),
            (.archiveNotFound(path: "/tmp/Xcode.xip"), "Archive not found: /tmp/Xcode.xip"),
            (.xipExtractionFailed(reason: "signature"), "Failed to extract XIP archive: signature"),
            (.xcodeAppNotFound(reason: "empty archive"), "Xcode.app not found in extracted archive: empty archive"),
            (.versionPlistNotFound(reason: "missing ProductBuildVersion"), "Version plist not found: missing ProductBuildVersion"),
            (.processTimedOut(tool: "hdiutil", seconds: 120), "hdiutil timed out after 120s")
        ]

        for (error, expectedDescription) in cases {
            #expect(error.errorDescription == expectedDescription)
        }
    }
}
