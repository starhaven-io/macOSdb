import macOSdbKit
import OSLog
import SwiftUI

@Observable
@MainActor
final class AppState {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "AppState")

    // MARK: - State

    var releases: [Release] = []
    var selectedRelease: Release?
    var compareRelease: Release?
    var isLoading = false
    var lastError: (any Error)?
    var searchText = ""
    var isComparing = false
    var showBetas = true

    // MARK: - Derived

    struct MajorVersionGroup: Identifiable, Equatable {
        let major: Int
        let name: String
        let releases: [Release]
        var id: Int { major }
    }

    var releasesByMajorVersion: [MajorVersionGroup] {
        let filtered = showBetas ? releases : releases.filter { !$0.isPrerelease }
        let grouped = Dictionary(grouping: filtered) { $0.majorVersion }
        return grouped.keys.sorted(by: >).compactMap { major in
            guard let releases = grouped[major] else { return nil }
            let sorted = releases.sorted(by: >)
            let name = sorted.first?.releaseName ?? "macOS \(major)"
            return MajorVersionGroup(major: major, name: name, releases: sorted)
        }
    }

    var comparison: VersionComparison? {
        guard let from = selectedRelease,
              let target = compareRelease else { return nil }
        return VersionComparer.compare(from: from, to: target)
    }

    // MARK: - Data provider

    private let dataProvider: DataProvider

    init(dataProvider: DataProvider? = nil) {
        if let dataProvider {
            self.dataProvider = dataProvider
        } else {
            // Try to find local data directory relative to the source tree
            let sourceFile = URL(fileURLWithPath: #filePath)
            let repoRoot = sourceFile
                .deletingLastPathComponent() // Models/
                .deletingLastPathComponent() // macOSdbApp/
                .deletingLastPathComponent() // repo root
            let localData = repoRoot.appendingPathComponent("data")
            let indexFile = localData.appendingPathComponent("releases.json")
            if FileManager.default.fileExists(atPath: indexFile.path) {
                self.dataProvider = DataProvider(baseURL: localData)
            } else {
                self.dataProvider = DataProvider()
            }
        }
    }

    // MARK: - Actions

    func refresh() async {
        isLoading = true
        lastError = nil
        await dataProvider.clearCache()

        do {
            let fetched = try await dataProvider.fetchAllReleases()
            releases = fetched.sorted(by: >)
            Self.logger.info("Loaded \(fetched.count) releases")
        } catch {
            lastError = error
            Self.logger.error("Failed to load releases: \(error.localizedDescription)")
        }

        isLoading = false
    }

    func startCompare() {
        isComparing = true
    }

    func endCompare() {
        isComparing = false
        compareRelease = nil
    }
}
