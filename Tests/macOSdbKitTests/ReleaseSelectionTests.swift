import Testing

@testable import macOSdbKit

/// `findRelease` resolves an `osVersion` to a single build. Several versions ship
/// more than one build under the same version string (device-specific re-releases,
/// betas, RCs), so the selection must prefer the general release rather than
/// whichever entry happens to come first in the index.
@Suite("findRelease selection")
struct ReleaseSelectionTests {

    private func entry(
        _ build: String,
        version: String = "15.1",
        beta: Bool = false,
        betaNumber: Int? = nil,
        rc: Bool = false,
        rcNumber: Int? = nil,
        deviceSpecific: Bool = false
    ) -> ReleaseIndexEntry {
        ReleaseIndexEntry(
            osVersion: version,
            buildNumber: build,
            releaseName: "macOS",
            isBeta: beta,
            betaNumber: betaNumber,
            isRC: rc,
            rcNumber: rcNumber,
            isDeviceSpecific: deviceSpecific,
            dataFile: "releases/15/macOS-\(version)-\(build).json"
        )
    }

    @Test("Prefers the universal GA over a device-specific build listed first")
    func prefersUniversalGAOverDeviceSpecific() {
        // Index order mirrors data/macos/releases.json for 15.1: device-specific first.
        let entries = [
            entry("24B2083", deviceSpecific: true),
            entry("24B83"),
            entry("24B82", rc: true, rcNumber: 1),
            entry("24B5070a", beta: true, betaNumber: 7)
        ]
        #expect(DataProvider.preferredRelease(among: entries)?.buildNumber == "24B83")
    }

    @Test("A final release wins even when only a device-specific GA and a beta exist")
    func finalReleaseBeatsBetaRegardlessOfDeviceSpecific() {
        let entries = [
            entry("24Bxxxx", beta: true, betaNumber: 3),
            entry("24B2091", deviceSpecific: true)
        ]
        #expect(DataProvider.preferredRelease(among: entries)?.buildNumber == "24B2091")
    }

    @Test("Falls back to the RC when no final release exists")
    func prefersRCOverBeta() {
        let entries = [
            entry("21A5552a", version: "12.0", beta: true, betaNumber: 11),
            entry("21A5506j", version: "12.0", rc: true, rcNumber: 1)
        ]
        #expect(DataProvider.preferredRelease(among: entries)?.buildNumber == "21A5506j")
    }

    @Test("Falls back to the latest beta when only betas exist")
    func prefersLatestBeta() {
        let entries = [
            entry("20A5384c", version: "11.0", beta: true, betaNumber: 7),
            entry("20A5395g", version: "11.0", beta: true, betaNumber: 9)
        ]
        #expect(DataProvider.preferredRelease(among: entries)?.buildNumber == "20A5395g")
    }

    @Test("Empty input returns nil")
    func emptyReturnsNil() {
        #expect(DataProvider.preferredRelease(among: []) == nil)
    }
}
