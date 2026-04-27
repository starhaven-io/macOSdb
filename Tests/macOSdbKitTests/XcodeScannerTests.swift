import Foundation
import Testing

@testable import macOSdbKit

@Suite("XcodeScanner tests")
struct XcodeScannerTests {

    @Test("xipFilename prefers `path` query parameter (services-account portal URL)")
    func xipFilenameFromServicesAccountURL() {
        let url = "https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_26.5_beta_3/Xcode_26.5_beta_3_Apple_silicon.xip"
        #expect(XcodeScanner.xipFilename(fromURLString: url) == "Xcode_26.5_beta_3_Apple_silicon.xip")
    }

    @Test("xipFilename falls back to lastPathComponent for direct CDN URL")
    func xipFilenameFromCDNURL() {
        let url = "https://adcdownload.apple.com/Developer_Tools/Xcode_26/Xcode_26_Universal.xip"
        #expect(XcodeScanner.xipFilename(fromURLString: url) == "Xcode_26_Universal.xip")
    }

    @Test("xipFilename returns nil for nil or invalid input")
    func xipFilenameNilInput() {
        #expect(XcodeScanner.xipFilename(fromURLString: nil) == nil)
        #expect(XcodeScanner.xipFilename(fromURLString: "") == nil)
    }
}
