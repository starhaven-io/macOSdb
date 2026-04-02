import Foundation
import Testing

@testable import macOSdbKit

@Suite("Binary string scanner tests")
struct BinaryStringScannerTests {

    @Test("Extract ASCII strings from binary data")
    func extractStrings() {
        // Build some binary data with embedded strings
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "hello".utf8)
        bytes.append(0x00)
        bytes.append(0xFF) // non-printable
        bytes.append(contentsOf: "curl 8.7.1".utf8)
        bytes.append(0x00)
        bytes.append(0x01) // non-printable
        bytes.append(contentsOf: "ab".utf8) // too short (< 4)
        bytes.append(0x00)

        let data = Data(bytes)
        let strings = BinaryStringScanner.extractStrings(from: data)

        #expect(strings.count == 2)
        #expect(strings[0] == "hello")
        #expect(strings[1] == "curl 8.7.1")
    }

    @Test("Minimum length filter")
    func minimumLength() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "abc".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "abcd".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let strings = BinaryStringScanner.extractStrings(from: data, minLength: 4)

        #expect(strings.count == 1)
        #expect(strings[0] == "abcd")
    }

    @Test("Find first matching pattern")
    func findFirst() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "curl 8.7.1".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "curl 8.8.0".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let match = BinaryStringScanner.findFirst(
            in: data,
            matching: #"curl [0-9]+\.[0-9]+\.[0-9]+"#
        )

        #expect(match == "curl 8.7.1")
    }

    @Test("Find all matching patterns")
    func findAll() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "version 1.2.3".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "other stuff".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: "version 4.5.6".utf8)
        bytes.append(0x00)

        let data = Data(bytes)
        let matches = BinaryStringScanner.findAll(
            in: data,
            matching: #"[0-9]+\.[0-9]+\.[0-9]+"#
        )

        #expect(matches.count == 2)
        #expect(matches[0] == "1.2.3")
        #expect(matches[1] == "4.5.6")
    }

    @Test("No matches returns nil/empty")
    func noMatches() {
        let data = Data("no version here".utf8)
        let match = BinaryStringScanner.findFirst(
            in: data,
            matching: #"[0-9]+\.[0-9]+\.[0-9]+"#
        )
        #expect(match == nil)

        let allMatches = BinaryStringScanner.findAll(
            in: data,
            matching: #"[0-9]+\.[0-9]+\.[0-9]+"#
        )
        #expect(allMatches.isEmpty)
    }

    @Test("Empty data returns empty results")
    func emptyData() {
        let strings = BinaryStringScanner.extractStrings(from: Data())
        #expect(strings.isEmpty)
    }

    @Test("Handles trailing string without null terminator")
    func trailingString() {
        let data = Data("hello world".utf8)
        let strings = BinaryStringScanner.extractStrings(from: data)
        #expect(strings.count == 1)
        #expect(strings[0] == "hello world")
    }
}

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

@Suite("Scanner config tests")
struct ScannerConfigTests {

    @Test("Filesystem component definitions cover expected binaries")
    func filesystemComponentsCoverage() {
        let names = Set(filesystemComponents.map(\.name))
        #expect(names.contains("curl"))
        #expect(names.contains("OpenSSH"))
        #expect(names.contains("LibreSSL"))
        #expect(names.contains("Ruby"))
        #expect(names.contains("SQLite"))
        #expect(names.contains("vim"))
        #expect(names.contains("httpd"))
        #expect(names.contains("zsh"))
    }

    @Test("dyld cache component definitions cover expected libraries")
    func dyldComponentsCoverage() {
        let names = Set(dyldCacheComponents.map(\.name))
        #expect(names.contains("libcurl"))
        #expect(names.contains("libssl (LibreSSL)"))
        #expect(names.contains("libxml2"))
        #expect(names.contains("libsqlite3"))
        #expect(names.contains("libpcap"))
        #expect(names.contains("libbz2 (bzip2)"))
        #expect(names.contains("libexpat"))
        #expect(names.contains("libncurses"))
    }

    @Test("Curl normalization strips prefix")
    func curlNormalization() {
        let curl = filesystemComponents.first { $0.name == "curl" }!
        #expect(curl.normalize("curl 8.7.1") == "8.7.1")
    }

    @Test("OpenSSH normalization strips prefix")
    func opensshNormalization() {
        let ssh = filesystemComponents.first { $0.name == "OpenSSH" }!
        #expect(ssh.normalize("OpenSSH_9.9p2") == "9.9p2")
    }

    @Test("Apache normalization strips prefix")
    func apacheNormalization() {
        let httpd = filesystemComponents.first { $0.name == "httpd" }!
        #expect(httpd.normalize("Apache/2.4.62") == "2.4.62")
    }

    @Test("vim normalization strips prefix")
    func vimNormalization() {
        let vim = filesystemComponents.first { $0.name == "vim" }!
        #expect(vim.normalize("VIM - Vi IMproved 9.1") == "9.1")
    }

    @Test("zsh normalization strips prefix")
    func zshNormalization() {
        let zsh = filesystemComponents.first { $0.name == "zsh" }!
        #expect(zsh.normalize("zsh-5.9") == "5.9")
    }

    @Test("libxml2 uses integer decode strategy")
    func libxml2Strategy() {
        let libxml2 = dyldCacheComponents.first { $0.name == "libxml2" }!
        #expect(libxml2.strategy == .integerDecode)
    }

    @Test("Toolchain component definitions cover expected binaries")
    func toolchainComponentsCoverage() {
        let names = Set(toolchainComponents.map(\.name))
        #expect(names.contains("Apple Clang"))
        #expect(names.contains("cctools"))
        #expect(names.contains("Swift"))
        #expect(names.contains("ld"))
    }

    @Test("Developer component definitions cover expected binaries")
    func developerComponentsCoverage() {
        let names = Set(developerComponents.map(\.name))
        #expect(names.contains("Git"))
    }

    @Test("Apple Clang normalization strips prefix")
    func clangNormalization() {
        let clang = toolchainComponents.first { $0.name == "Apple Clang" }!
        #expect(clang.normalize("clang-2100.0.123.102") == "2100.0.123.102")
        #expect(clang.normalize("clang-1300.0.29.30") == "1300.0.29.30")
    }

    @Test("cctools normalization strips prefix")
    func cctoolsNormalization() {
        let cctools = toolchainComponents.first { $0.name == "cctools" }!
        #expect(cctools.normalize("cctools-1040") == "1040")
        #expect(cctools.normalize("cctools-973") == "973")
    }

    @Test("Swift normalization strips prefix for both formats")
    func swiftNormalization() {
        let swift = toolchainComponents.first { $0.name == "Swift" }!
        #expect(swift.normalize("swiftlang-6.3.0.123.5") == "6.3")
        #expect(swift.normalize("Swift version 5.5.2") == "5.5.2")
    }

    @Test("ld normalization strips PROJECT prefix for both ld and ld64")
    func ldNormalization() {
        let ld = toolchainComponents.first { $0.name == "ld" }!
        #expect(ld.normalize("PROJECT:ld64-711") == "711")
        #expect(ld.normalize("PROJECT:ld-1230.1") == "1230.1")
        #expect(ld.normalize("PROJECT:dyld-1022.1") == "1022.1")
    }

    @Test("Git normalization strips Apple Git suffix")
    func gitNormalization() {
        let git = developerComponents.first { $0.name == "Git" }!
        #expect(git.normalize("2.39.3 (Apple Git-146)") == "2.39.3")
        #expect(git.normalize("2.47.1 (Apple Git-162)") == "2.47.1")
        #expect(git.normalize("2.37.1 (Apple Git-137.1)") == "2.37.1")
    }

    @Test("Framework component definitions cover expected binaries")
    func frameworkComponentsCoverage() {
        let names = Set(frameworkComponents.map(\.name))
        #expect(names.contains("lldb"))
    }

    @Test("lldb normalization strips prefix")
    func lldbNormalization() {
        let lldb = frameworkComponents.first { $0.name == "lldb" }!
        #expect(lldb.normalize("lldb-2100.0.16.4") == "2100.0.16.4")
        #expect(lldb.normalize("lldb-1316.0.9.46") == "1316.0.9.46")
    }

    @Test("All regex patterns compile")
    func allPatternsCompile() {
        for def in filesystemComponents + dyldCacheComponents + toolchainComponents
                    + developerComponents + frameworkComponents {
            let swiftRegex = try? Regex(def.pattern)
            let nsRegex = try? NSRegularExpression(pattern: def.pattern)
            #expect(
                swiftRegex != nil || nsRegex != nil,
                "Pattern failed to compile for \(def.name): \(def.pattern)"
            )
        }
    }

    @Test("Regex patterns match expected real-world strings")
    func patternsMatchRealData() throws {
        struct TestCase {
            let name: String
            let input: String
            let expected: String
        }

        let testCases: [TestCase] = [
            TestCase(name: "curl", input: "curl 8.7.1", expected: "curl 8.7.1"),
            TestCase(name: "OpenSSH", input: "OpenSSH_9.9p2", expected: "OpenSSH_9.9p2"),
            TestCase(name: "LibreSSL", input: "LibreSSL 3.3.6", expected: "LibreSSL 3.3.6"),
            TestCase(name: "SQLite", input: "3.43.2", expected: "3.43.2"),
            TestCase(name: "vim", input: "VIM - Vi IMproved 9.1", expected: "VIM - Vi IMproved 9.1"),
            TestCase(name: "httpd", input: "Apache/2.4.62", expected: "Apache/2.4.62"),
            TestCase(name: "zsh", input: "zsh-5.9-0-g73d3173", expected: "zsh-5.9"),
            // Toolchain components
            TestCase(name: "Apple Clang", input: "clang-2100.0.123.102", expected: "clang-2100.0.123.102"),
            TestCase(name: "cctools", input: "cctools-1040", expected: "cctools-1040"),
            TestCase(name: "Swift", input: "swiftlang-6.3.0.123.5", expected: "swiftlang-6.3.0.123.5"),
            TestCase(name: "Swift", input: "Swift version 5.5.2", expected: "Swift version 5.5.2"),
            TestCase(name: "ld", input: "PROJECT:ld64-711.1", expected: "PROJECT:ld64-711.1"),
            TestCase(name: "ld", input: "PROJECT:ld-1230.1", expected: "PROJECT:ld-1230.1"),
            TestCase(name: "ld", input: "PROJECT:dyld-1022.1", expected: "PROJECT:dyld-1022.1"),
            // Developer components
            TestCase(
                name: "Git",
                input: "2.39.3 (Apple Git-146)",
                expected: "2.39.3 (Apple Git-146)"
            ),
            TestCase(
                name: "Git",
                input: "2.37.1 (Apple Git-137.1)",
                expected: "2.37.1 (Apple Git-137.1)"
            ),
            // Framework components
            TestCase(name: "lldb", input: "lldb-2100.0.16.4", expected: "lldb-2100.0.16.4"),
            TestCase(name: "lldb", input: "lldb-1316.0.9.46", expected: "lldb-1316.0.9.46")
        ]

        let allComponents = filesystemComponents + toolchainComponents + developerComponents
            + frameworkComponents

        for testCase in testCases {
            let name = testCase.name
            let input = testCase.input
            let expected = testCase.expected
            guard let def = allComponents.first(where: { $0.name == name }) else {
                Issue.record("Component definition not found: \(name)")
                continue
            }

            let regex = try Regex(def.pattern)
            let match = input.firstMatch(of: regex)
            #expect(match != nil, "Pattern for \(name) did not match '\(input)'")

            if let match {
                #expect(String(input[match.range]) == expected)
            }
        }
    }
}
