import Foundation
import Testing

@testable import macOSdbKit

@Suite("Version comparison tests")
struct VersionComparerTests {

    // MARK: - Version string comparison

    @Test("Simple version upgrade")
    func simpleUpgrade() {
        #expect(VersionComparer.compareVersionStrings("8.7.0", "8.7.1") == .upgraded)
    }

    @Test("Simple version downgrade")
    func simpleDowngrade() {
        #expect(VersionComparer.compareVersionStrings("8.7.1", "8.7.0") == .downgraded)
    }

    @Test("Identical versions are unchanged")
    func unchanged() {
        #expect(VersionComparer.compareVersionStrings("1.2.3", "1.2.3") == .unchanged)
    }

    @Test("Major version upgrade")
    func majorUpgrade() {
        #expect(VersionComparer.compareVersionStrings("2.39.3", "2.39.5") == .upgraded)
    }

    @Test("Version with p suffix — OpenSSH style")
    func versionWithPSuffix() {
        #expect(VersionComparer.compareVersionStrings("9.7p1", "9.9p2") == .upgraded)
        #expect(VersionComparer.compareVersionStrings("9.8p1", "9.8p1") == .unchanged)
    }

    @Test("Version with parenthetical suffix stripped")
    func versionWithParentheticalSuffix() {
        // Parenthetical suffixes are stripped for robustness
        #expect(VersionComparer.compareVersionStrings(
            "2.9.13 (beta)", "2.12.9 (release)"
        ) == .upgraded)
    }

    @Test("Two-component version")
    func twoComponentVersion() {
        #expect(VersionComparer.compareVersionStrings("9.0", "9.1") == .upgraded)
        #expect(VersionComparer.compareVersionStrings("3.0", "3.0") == .unchanged)
    }

    @Test("Different length versions — zero-padded comparison")
    func differentLengthVersions() {
        #expect(VersionComparer.compareVersionStrings("1.2", "1.2.1") == .upgraded)
        #expect(VersionComparer.compareVersionStrings("1.2.1", "1.2") == .downgraded)
    }

    // MARK: - Release comparison

    @Test("Compare two releases — detects changes")
    func compareTwoReleases() {
        let from = Release(
            osVersion: "14.6.1",
            buildNumber: "23G93",
            releaseName: "Sonoma",
            components: [
                Component(name: "OpenSSH", version: "9.7p1", path: "/usr/bin/ssh"),
                Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                Component(name: "httpd", version: "2.4.59", path: "/usr/sbin/httpd"),
                Component(
                    name: "libexpat", version: "2.5.0",
                    path: "/usr/lib/libexpat.1.dylib",
                    source: .dyldCache
                )
            ]
        )

        let toRel = Release(
            osVersion: "15.6.1",
            buildNumber: "24G90",
            releaseName: "Sequoia",
            components: [
                Component(name: "OpenSSH", version: "9.9p2", path: "/usr/bin/ssh"),
                Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                Component(name: "httpd", version: "2.4.62", path: "/usr/sbin/httpd"),
                Component(
                    name: "libexpat", version: "2.7.1",
                    path: "/usr/lib/libexpat.1.dylib",
                    source: .dyldCache
                )
            ]
        )

        let comparison = VersionComparer.compare(from: from, to: toRel)

        #expect(comparison.changes.count == 4)
        #expect(comparison.addedComponents.isEmpty)
        #expect(comparison.removedComponents.isEmpty)

        // OpenSSH upgraded
        let openssh = comparison.changes.first { $0.name == "OpenSSH" }
        #expect(openssh?.direction == .upgraded)
        #expect(openssh?.fromVersion == "9.7p1")
        #expect(openssh?.toVersion == "9.9p2")

        // curl unchanged
        let curl = comparison.changes.first { $0.name == "curl" }
        #expect(curl?.direction == .unchanged)

        // httpd upgraded
        let apache = comparison.changes.first { $0.name == "httpd" }
        #expect(apache?.direction == .upgraded)

        // libexpat upgraded
        let expat = comparison.changes.first { $0.name == "libexpat" }
        #expect(expat?.direction == .upgraded)

        // Changed components filters out unchanged
        #expect(comparison.changedComponents.count == 3)
        #expect(comparison.upgradedComponents.count == 3)
        #expect(comparison.downgradedComponents.isEmpty)
    }

    @Test("Compare detects added and removed components")
    func compareAddedAndRemoved() {
        let from = Release(
            osVersion: "14.0",
            buildNumber: "23A",
            releaseName: "Sonoma",
            components: [
                Component(name: "curl", version: "8.4.0", path: "/usr/bin/curl"),
                Component(name: "oldtool", version: "1.0", path: "/usr/bin/oldtool")
            ]
        )

        let toRel = Release(
            osVersion: "15.0",
            buildNumber: "24A",
            releaseName: "Sequoia",
            components: [
                Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                Component(name: "newtool", version: "2.0", path: "/usr/bin/newtool")
            ]
        )

        let comparison = VersionComparer.compare(from: from, to: toRel)

        #expect(comparison.changes.count == 1) // curl
        #expect(comparison.addedComponents.count == 1)
        #expect(comparison.addedComponents[0].name == "newtool")
        #expect(comparison.removedComponents.count == 1)
        #expect(comparison.removedComponents[0].name == "oldtool")
    }

    @Test("Comparison summary string")
    func comparisonSummary() {
        let from = Release(
            osVersion: "14.6.1",
            buildNumber: "23G93",
            releaseName: "Sonoma",
            components: [
                Component(name: "OpenSSH", version: "9.7p1", path: "/usr/bin/ssh"),
                Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
            ]
        )

        let toRel = Release(
            osVersion: "15.6.1",
            buildNumber: "24G90",
            releaseName: "Sequoia",
            components: [
                Component(name: "OpenSSH", version: "9.9p2", path: "/usr/bin/ssh"),
                Component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
            ]
        )

        let comparison = VersionComparer.compare(from: from, to: toRel)
        #expect(comparison.summary == "1 upgraded, 0 downgraded, 0 added, 0 removed")
    }

    // MARK: - Fixture-based tests

    @Test("Compare fixture releases 14.6.1 → 15.6.1")
    func compareFixtureReleases() throws {
        let url14 = Bundle.module.url(
            forResource: "macOS-14.6.1-23G93", withExtension: "json", subdirectory: "Fixtures"
        )!
        let url15 = Bundle.module.url(
            forResource: "macOS-15.6.1-24G90", withExtension: "json", subdirectory: "Fixtures"
        )!

        let from = try JSONDecoder().decode(Release.self, from: Data(contentsOf: url14))
        let toRel = try JSONDecoder().decode(Release.self, from: Data(contentsOf: url15))

        let comparison = VersionComparer.compare(from: from, to: toRel)

        // OpenSSH should have been upgraded from 9.7p1 to 9.9p2
        let openssh = comparison.changes.first { $0.name == "OpenSSH" }
        #expect(openssh?.direction == .upgraded)

        // httpd should have been upgraded from 2.4.59 to 2.4.62
        let apache = comparison.changes.first { $0.name == "httpd" }
        #expect(apache?.direction == .upgraded)

        // libexpat should have been upgraded from 2.5.0 to 2.7.1
        let expat = comparison.changes.first { $0.name == "libexpat" }
        #expect(expat?.direction == .upgraded)

        // curl should be unchanged at 8.7.1
        let curl = comparison.changes.first { $0.name == "curl" }
        #expect(curl?.direction == .unchanged)

        // vim should have been upgraded from 9.0 to 9.1
        let vim = comparison.changes.first { $0.name == "vim" }
        #expect(vim?.direction == .upgraded)

        // rsync was added in 15.6.1
        #expect(comparison.addedComponents.contains { $0.name == "rsync" })
    }
}
