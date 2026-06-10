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
    /// Persists a load failure for the inline empty state until the next refresh,
    /// independent of `lastError`, which the alert clears on dismissal.
    var loadFailureMessage: String?
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
    var selectedSDKVersion: String?

    // MARK: - Types

    enum SidebarMode: String, CaseIterable {
        case releases = "Releases"
        case components = "Components"
        case sdks = "SDKs"
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

    struct SDKSummary: Identifiable, Hashable {
        let version: String
        let latestBuild: String?
        let xcodeReleaseCount: Int
        var id: String { version }
    }

    struct SDKVersionEntry: Identifiable {
        let sdkBuild: String?
        let xcodeDisplayName: String
        let xcodeBuild: String
        let xcodeReleaseDate: String?
        let isBeta: Bool
        let isRC: Bool
        /// True when this is the earliest Xcode release to ship this particular SDK build.
        let isFirstShippingBuild: Bool
        var id: String { xcodeBuild }
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

    var supportsSDKsMode: Bool {
        selectedProduct == .xcode
    }

    var availableSidebarModes: [SidebarMode] {
        supportsSDKsMode ? SidebarMode.allCases : [.releases, .components]
    }

    var allSDKs: [SDKSummary] {
        guard supportsSDKsMode else { return [] }
        let filtered = releases.filter { release in
            (showBetas || !release.isPrerelease) && (showDeviceSpecific || !release.isDeviceSpecific)
        }
        let sorted = filtered.sorted(by: >)

        var versionMap: [String: (latestBuild: String?, count: Int)] = [:]
        var order: [String] = []
        for release in sorted {
            guard let sdks = release.sdks else { continue }
            for sdk in sdks {
                if let existing = versionMap[sdk.sdkVersion] {
                    versionMap[sdk.sdkVersion] = (existing.latestBuild, existing.count + 1)
                } else {
                    versionMap[sdk.sdkVersion] = (sdk.buildVersion, 1)
                    order.append(sdk.sdkVersion)
                }
            }
        }
        return order.compactMap { version in
            guard let entry = versionMap[version] else { return nil }
            return SDKSummary(version: version, latestBuild: entry.latestBuild, xcodeReleaseCount: entry.count)
        }
    }

    var filteredSDKs: [SDKSummary] {
        let search = searchText.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return allSDKs }
        return allSDKs.filter {
            $0.version.localizedCaseInsensitiveContains(search)
                || ($0.latestBuild?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    func sdkHistory(for sdkVersion: String) -> [SDKVersionEntry] {
        guard supportsSDKsMode else { return [] }
        let filtered = releases.filter { release in
            (showBetas || !release.isPrerelease) && (showDeviceSpecific || !release.isDeviceSpecific)
        }

        // Walk oldest-first so we can mark the earliest release for each SDK build.
        var firstSeenBuilds = Set<String>()
        var oldestFirst: [SDKVersionEntry] = []
        for release in filtered.sorted(by: <) {
            guard let sdks = release.sdks else { continue }
            guard let sdk = sdks.first(where: { $0.sdkVersion == sdkVersion }) else { continue }
            let isFirstShipping = sdk.buildVersion.map { firstSeenBuilds.insert($0).inserted } ?? false
            oldestFirst.append(SDKVersionEntry(
                sdkBuild: sdk.buildVersion,
                xcodeDisplayName: release.displayName,
                xcodeBuild: release.buildNumber,
                xcodeReleaseDate: release.releaseDate,
                isBeta: release.isBeta,
                isRC: release.isRC,
                isFirstShippingBuild: isFirstShipping
            ))
        }
        return oldestFirst.reversed()
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
            return
        }

        #if DEBUG
        // DEBUG-only: prefer the repo's local data/ dir. #filePath is compile-time,
        // so gating on DEBUG keeps the dev's absolute path out of release builds.
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent() // Models/
            .deletingLastPathComponent() // macOSdbApp/
            .deletingLastPathComponent() // repo root
        let localData = repoRoot.appendingPathComponent("data")
        let indexFile = localData.appendingPathComponent("macos/releases.json")
        if FileManager.default.fileExists(atPath: indexFile.path) {
            self.dataProvider = DataProvider(baseURL: localData)
            return
        }
        #endif

        self.dataProvider = DataProvider()
    }

    // MARK: - Actions

    /// Loads the current product's releases, reusing any cached data. Used on launch
    /// and when switching products so a flip doesn't re-download the whole catalog —
    /// the DataProvider caches are product-keyed and URLCache serves repeat launches.
    func load() async {
        isLoading = true
        lastError = nil
        loadFailureMessage = nil

        do {
            let fetched = try await dataProvider.fetchAllReleases(for: selectedProduct)
            releases = fetched.sorted(by: >)
            reconcileSelection()
            Self.logger.info("Loaded \(fetched.count) \(self.selectedProduct.displayName) releases")
        } catch {
            lastError = error
            loadFailureMessage = error.localizedDescription
            Self.logger.error("Failed to load \(self.selectedProduct.displayName) releases: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Discards cached data and reloads from the network. Backs the ⌘R Refresh
    /// command so the user can pull in newly published releases.
    func refresh() async {
        await dataProvider.clearCache()
        await load()
    }

    /// Re-point the current selection/comparison at the freshly loaded instances so
    /// the detail panes don't keep rendering a stale snapshot (or a release that is
    /// no longer in the catalog) after a refresh.
    private func reconcileSelection() {
        if let selected = selectedRelease {
            selectedRelease = releases.first { $0.buildNumber == selected.buildNumber }
        }
        if let compare = compareRelease {
            compareRelease = releases.first { $0.buildNumber == compare.buildNumber }
        }
    }

    func switchProduct(_ product: ProductType) {
        guard product != selectedProduct else { return }
        selectedProduct = product
        selectedRelease = nil
        compareRelease = nil
        selectedComponentName = nil
        selectedSDKVersion = nil
        if sidebarMode == .sdks && product != .xcode {
            sidebarMode = .releases
        }
        isComparing = false
        releases = []
        Task { await load() }
    }

    func startCompare() {
        isComparing = true
    }

    func endCompare() {
        isComparing = false
        compareRelease = nil
    }
}
