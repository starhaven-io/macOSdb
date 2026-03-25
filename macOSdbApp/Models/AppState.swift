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
    var searchText = ""
    var isComparing = false
    var showBetas = true
    var showDeviceSpecific = false

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
        if pendingCounterpartVersion != nil {
            // Defer selection to next run loop so the List has time to render with new data
            Task { @MainActor in
                selectPendingCounterpart()
            }
        }
    }

    func switchProduct(_ product: ProductType) {
        guard product != selectedProduct else { return }
        selectedProduct = product
        selectedRelease = nil
        compareRelease = nil
        isComparing = false
        releases = []
        Task { await refresh() }
    }

    private var pendingCounterpartVersion: String?

    func navigateToCounterpart(_ release: Release, in targetProduct: ProductType) {
        pendingCounterpartVersion = release.osVersion
        switchProduct(targetProduct)
    }

    private func selectPendingCounterpart() {
        guard let version = pendingCounterpartVersion else { return }
        pendingCounterpartVersion = nil

        let parts = version.split(separator: ".")
        let major = parts.first.flatMap { Int($0) }
        let minor = parts.count > 1 ? Int(parts[1]) : nil

        selectedRelease = releases.first { $0.osVersion == version }
            ?? releases.first {
                $0.majorVersion == major && $0.minorVersion == minor
            }
            ?? releases.first { $0.majorVersion == major }
    }

    func startCompare() {
        isComparing = true
    }

    func endCompare() {
        isComparing = false
        compareRelease = nil
    }
}
