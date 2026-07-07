import Testing

@testable import macOSdbCore

@Suite("Build number ordering")
struct BuildNumberOrderingTests {

    @Test("Re-release variant sorts after the original (numeric, not lexicographic)")
    func reReleaseOrdering() {
        // Lexicographically "24B2083" < "24B83" (because '2' < '8'); numerically 83 < 2083.
        #expect(BuildNumber.less("24B83", "24B2083"))
        #expect(!BuildNumber.less("24B2083", "24B83"))
    }

    @Test("Orders by cycle, then train, then build, then suffix")
    func componentOrdering() {
        #expect(BuildNumber.less("23G93", "24A100"))     // cycle: 23 < 24
        #expect(BuildNumber.less("24A300", "24B83"))     // train: A < B
        #expect(BuildNumber.less("25A8364", "25A8365"))  // build: 8364 < 8365
        #expect(BuildNumber.less("24A5331", "24A5331b")) // suffix: "" < "b"
    }

    @Test("Equal build numbers are not less than each other")
    func equalBuilds() {
        #expect(!BuildNumber.less("24G90", "24G90"))
    }

    @Test("Release index descending uses build number after maturity")
    func releaseIndexDescendingUsesBuildNumberAfterMaturity() {
        let entries = [
            entry(build: "20B28", isRC: true, rcNumber: 2),
            entry(build: "20B5011a", isBeta: true, betaNumber: 2),
            entry(build: "20B5012d", isBeta: true, betaNumber: 1),
            entry(build: "20B5022a", isRC: true),
            entry(build: "20B29")
        ].sorted(by: ReleaseIndexEntry.versionDescending)

        #expect(entries.map(\.buildNumber) == ["20B29", "20B5022a", "20B28", "20B5012d", "20B5011a"])
    }

    private func entry(
        build: String,
        isBeta: Bool = false,
        betaNumber: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil
    ) -> ReleaseIndexEntry {
        ReleaseIndexEntry(
            osVersion: "11.0.1",
            buildNumber: build,
            releaseName: "Big Sur",
            releaseDate: "2020-11-01",
            isBeta: isBeta,
            betaNumber: betaNumber,
            isRC: isRC,
            rcNumber: rcNumber,
            dataFile: "releases/11/macOS-11.0.1-\(build).json"
        )
    }
}

@Suite("Chip family resolution")
struct ChipFamilyResolutionTests {

    @Test("Falls back to the arch suffix when the chip label is unmapped")
    func archSuffixFallback() {
        // Older data: chip label "Multiple" maps to no display name and there are no
        // deviceChips, so resolution must fall back to the arch suffix.
        let kernel = KernelInfo(
            file: "kernelcache.release.mac15",
            darwinVersion: "24.0.0",
            arch: "ARM64_T8132",
            chip: "Multiple",
            devices: ["Mac16,1", "Mac16,2"]
        )
        #expect(kernel.resolvedChipFamilies == [.m4])
    }

    @Test("Per-device chips take priority over the arch fallback")
    func deviceChipsPreferred() {
        let kernel = KernelInfo(
            file: "kernelcache.release.mac15",
            darwinVersion: "24.0.0",
            arch: "ARM64_T6041",
            chip: "Multiple",
            devices: ["Mac16,5"],
            deviceChips: [DeviceChip(device: "Mac16,5", chip: "M4 Max")]
        )
        #expect(kernel.resolvedChipFamilies == [.m4Max])
    }
}
