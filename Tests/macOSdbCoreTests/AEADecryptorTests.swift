import Foundation
import Testing

@testable import macOSdbCore

@Suite("AEA decryptor tests")
struct AEADecryptorTests {

    @Test("WKMS URLs are restricted to HTTPS Apple hosts")
    func wkmsURLAllowlist() throws {
        #expect(AEADecryptor.isAllowedWKMSURL(URL(string: "https://gdmf.apple.com/key.pem")!))
        #expect(AEADecryptor.isAllowedWKMSURL(URL(string: "https://updates.cdn-apple.com/key.pem")!))

        #expect(!AEADecryptor.isAllowedWKMSURL(URL(string: "http://gdmf.apple.com/key.pem")!))
        #expect(!AEADecryptor.isAllowedWKMSURL(URL(string: "https://apple.com.evil.example/key.pem")!))
        #expect(!AEADecryptor.isAllowedWKMSURL(URL(string: "https://127.0.0.1/key.pem")!))
        #expect(!AEADecryptor.isAllowedWKMSURL(URL(string: "https://user:pass@gdmf.apple.com/key.pem")!))
    }
}
