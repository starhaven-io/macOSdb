import macOSdbKit
import OSLog
import SwiftUI

@Observable
@MainActor
final class AppState {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "AppState")

    // MARK: - State

    var selectedProduct: ProductType = .macOS
    var releases: [Release] = []
    var selectedRelease: Release?
    var compareRelease: Release?
    var isLoading = false
    var lastError: (any Error)?
    var hasError: Bool {
        get { lastError != nil }
        set { if !newValue { lastError = nil } }
    }
    var searchText = ""
    var isComparing = false
    var showBetas = true
    var showDeviceSpecific = false
    var sidebarMode: SidebarMode = .releases
    var selectedComponentName: String?

    // MARK: - Types

    enum SidebarMode: String, CaseIterable {
        case releases = "Releases"
        case components = "Components"
    }

    struct ComponentSummary: Identifiable, Hashable {
        let name: String
        let latestVersion: String
        let source: ComponentSource
        let path: String
        var id: String { name }
    }

    struct ComponentVersionEntry: Identifiable {
        let version: String
        let releaseName: String
        let releaseDate: String?
        let isBeta: Bool
        let isRC: Bool
        let direction: ChangeDirection?
        var id: String { "\(releaseName)-\(version)" }
    }

    // MARK: - Derived

    struct MajorVersionGroup: Identifiable, Equatable {
        let major: Int
        let name: String
        let releases: [Release]
        var id: Int { major }
    }

    var releasesByMajorVersion: [MajorVersionGroup] {
        let filtered = releases.filter { release in
            (showBetas || !release.isPrerelease) && (showDeviceSpecific || !release.isDeviceSpecific)
        }
        let grouped = Dictionary(grouping: filtered) { $0.majorVersion }
        return grouped.keys.sorted(by: >).compactMap { major in
            guard let releases = grouped[major] else { return nil }
            let sorted = releases.sorted(by: >)
            let name: String
            switch selectedProduct {
            case .macOS:
                name = sorted.first?.releaseName ?? "macOS \(major)"
            case .xcode:
                name = "Xcode \(major)"
            }
            return MajorVersionGroup(major: major, name: name, releases: sorted)
        }
    }

    var comparison: VersionComparison? {
        guard let from = selectedRelease,
              let target = compareRelease else { return nil }
        return VersionComparer.compare(from: from, to: target)
    }

    var allComponents: [ComponentSummary] {
        let filtered = releases.filter { release in
            (showBetas || !release.isPrerelease) && (showDeviceSpecific || !release.isDeviceSpecific)
        }
        let sorted = filtered.sorted(by: >)

        var seen = Set<String>()
        var result: [ComponentSummary] = []
        for release in sorted {
            for comp in release.components where seen.insert(comp.name).inserted {
                result.append(ComponentSummary(
                    name: comp.name,
                    latestVersion: comp.displayVersion,
                    source: comp.source,
                    path: comp.path
                ))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var filteredComponents: [ComponentSummary] {
        let search = searchText.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return allComponents }
        return allComponents.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.latestVersion.localizedCaseInsensitiveContains(search)
        }
    }

    func componentHistory(for name: String) -> [ComponentVersionEntry] {
        let filtered = releases.filter { release in
            (showBetas || !release.isPrerelease) && (showDeviceSpecific || !release.isDeviceSpecific)
        }

        var versionMap: [String: Release] = [:]
        for release in filtered.sorted(by: <) {
            guard let comp = release.component(named: name) else { continue }
            let ver = comp.displayVersion
            if versionMap[ver] == nil {
                versionMap[ver] = release
            }
        }

        let sorted = versionMap.keys.sorted {
            VersionComparer.compareVersionStrings($0, $1) == .upgraded
        }

        let entries: [ComponentVersionEntry] = sorted.enumerated().map { index, version in
            let release = versionMap[version]!
            let direction: ChangeDirection? = index == 0
                ? nil
                : VersionComparer.compareVersionStrings(sorted[index - 1], version)
            return ComponentVersionEntry(
                version: version,
                releaseName: release.displayName,
                releaseDate: release.releaseDate,
                isBeta: release.isBeta,
                isRC: release.isRC,
                direction: direction
            )
        }

        return entries.reversed()
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
            let indexFile = localData.appendingPathComponent("macos/releases.json")
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
            let fetched = try await dataProvider.fetchAllReleases(for: selectedProduct)
            releases = fetched.sorted(by: >)
            Self.logger.info("Loaded \(fetched.count) \(self.selectedProduct.displayName) releases")
        } catch {
            lastError = error
            Self.logger.error("Failed to load \(self.selectedProduct.displayName) releases: \(error.localizedDescription)")
        }

        isLoading = false
    }

    func switchProduct(_ product: ProductType) {
        guard product != selectedProduct else { return }
        selectedProduct = product
        selectedRelease = nil
        compareRelease = nil
        selectedComponentName = nil
        isComparing = false
        releases = []
        Task { await refresh() }
    }

    func startCompare() {
        isComparing = true
    }

    func endCompare() {
        isComparing = false
        compareRelease = nil
    }
}
