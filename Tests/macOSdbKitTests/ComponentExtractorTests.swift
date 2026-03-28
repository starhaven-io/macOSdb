import Foundation
import Testing

@testable import macOSdbKit

@Suite("Component extractor tests")
struct ComponentExtractorTests {

    @Test("Extract curl version from binary data")
    func extractCurl() {
        var bytes: [UInt8] = [0x00, 0x00, 0x00]
        bytes.append(contentsOf: "curl 8.7.1 (x86_64-apple-darwin24.0)".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "other stuff".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = filesystemComponents.first { $0.name == "curl" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component != nil)
        #expect(component?.name == "curl")
        #expect(component?.version == "8.7.1")
        #expect(component?.source == .filesystem)
    }

    @Test("Extract OpenSSH version")
    func extractOpenSSH() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "OpenSSH_9.9p2, LibreSSL 3.3.6".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = filesystemComponents.first { $0.name == "OpenSSH" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.version == "9.9p2")
    }

    @Test("Integer decode for libxml2")
    func extractLibxml2IntegerDecode() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "20913".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = dyldCacheComponents.first { $0.name == "libxml2" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.version == "2.9.13")
        #expect(component?.source == .dyldCache)
    }

    @Test("No match returns nil")
    func noMatchReturnsNil() {
        var bytes: [UInt8] = [0x00, 0x00]
        bytes.append(contentsOf: "no version here".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = ComponentDefinition(
            name: "TestBinary",
            path: "usr/bin/testbinary",
            source: .filesystem,
            pattern: #"NOMATCH_[0-9]+\.[0-9]+\.[0-9]+"#,
            normalize: { $0 },
            strategy: .regex
        )
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component == nil)
    }

    @Test("libpcap requires upstream version string format")
    func libpcapUpstreamFormat() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "libpcap version 1.10.1 (with TPACKET_V3)".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "98.100.3".utf8) // Apple internal version — should be ignored
        bytes.append(0x00)

        let data = Data(bytes)
        let def = dyldCacheComponents.first { $0.name == "libpcap" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.version == "1.10.1")
    }

    @Test("Extract Apple Clang version from binary data")
    func extractClang() {
        var bytes: [UInt8] = [0x00, 0x00]
        bytes.append(contentsOf: "clang-2100.0.123.102".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = toolchainComponents.first { $0.name == "Apple Clang" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.name == "Apple Clang")
        #expect(component?.version == "2100.0.123.102")
    }

    @Test("Extract cctools version from binary data")
    func extractCctools() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "cctools-1040".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = toolchainComponents.first { $0.name == "cctools" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.name == "cctools")
        #expect(component?.version == "1040")
    }

    @Test("Extract Swift version from binary data")
    func extractSwift() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "swiftlang-6.3.0.123.5".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = toolchainComponents.first { $0.name == "Swift" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.version == "6.3.0.123.5")
    }

    @Test("Extract ld version — modern format")
    func extractLdModern() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "PROJECT:ld-1230.1".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = toolchainComponents.first { $0.name == "ld" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.version == "1230.1")
    }

    @Test("Extract ld version — legacy ld64 format")
    func extractLd64Legacy() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "PROJECT:ld64-711".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = toolchainComponents.first { $0.name == "ld" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.version == "711")
    }

    @Test("Extract Git version stripping Apple Git suffix")
    func extractGit() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "2.39.3 (Apple Git-146)".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = developerComponents.first { $0.name == "Git" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.name == "Git")
        #expect(component?.version == "2.39.3")
    }

    @Test("Extract lldb version from framework binary data")
    func extractLLDB() {
        var bytes: [UInt8] = [0x00, 0x00]
        bytes.append(contentsOf: "lldb-2100.0.16.4".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "other stuff".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let def = frameworkComponents.first { $0.name == "lldb" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component?.name == "lldb")
        #expect(component?.version == "2100.0.16.4")
    }

    @Test("libpcap skips bare version numbers")
    func libpcapRejectsAppleVersion() {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: "98.100.3".utf8) // Apple internal, no "libpcap version" prefix
        bytes.append(0x00)

        let data = Data(bytes)
        let def = dyldCacheComponents.first { $0.name == "libpcap" }!
        let component = ComponentExtractor.extract(from: data, using: def)

        #expect(component == nil)
    }
}
