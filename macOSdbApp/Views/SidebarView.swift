import macOSdbKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self)
    private var appState

    @State private var expandedGroups: Set<Int> = []
    @State private var hasInitializedExpansion = false

    var body: some View {
        @Bindable var state = appState

        List(selection: appState.isComparing ? $state.compareRelease : $state.selectedRelease) {
            if appState.isLoading && appState.releases.isEmpty {
                ProgressView("Loading releases...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if appState.releases.isEmpty {
                ContentUnavailableView(
                    "No Releases",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Could not load release data. Check your network connection.")
                )
            } else {
                ForEach(appState.releasesByMajorVersion) { group in
                    DisclosureGroup(isExpanded: expandedBinding(for: group.major)) {
                        ForEach(group.releases) { release in
                            ReleaseRow(release: release)
                                .tag(release)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sidebarGroupLabel(group))
                                .font(.callout)
                            Text(groupCountLabel(for: group))
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: appState.releasesByMajorVersion) { old, new in
            if hasInitializedExpansion {
                let newMajors = Set(new.map(\.major)).subtracting(old.map(\.major))
                expandedGroups.formUnion(newMajors)
            } else {
                initializeExpansionIfNeeded()
            }
        }
        .onAppear {
            initializeExpansionIfNeeded()
        }
        .id(appState.selectedProduct)
        .listStyle(.sidebar)
        .navigationTitle("macOSdb")
        .safeAreaInset(edge: .top) {
            Picker("Product", selection: productBinding) {
                ForEach(ProductType.allCases, id: \.self) { product in
                    Text(product.displayName).tag(product)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .bottom) {
            if appState.isComparing {
                Text("Select a release to compare with")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show pre-releases", isOn: $state.showBetas)
                        .toggleStyle(.checkbox)
                    Toggle("Show device specific", isOn: $state.showDeviceSpecific)
                        .toggleStyle(.checkbox)
                    Text(totalCountLabel)
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        }
    }

    private func expandedBinding(for major: Int) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(major) },
            set: { isExpanded in
                if isExpanded {
                    expandedGroups.insert(major)
                } else {
                    expandedGroups.remove(major)
                }
            }
        )
    }

    private func initializeExpansionIfNeeded() {
        guard !hasInitializedExpansion, !appState.releasesByMajorVersion.isEmpty else { return }
        expandedGroups = Set(appState.releasesByMajorVersion.map(\.major))
        hasInitializedExpansion = true
    }

    private func sidebarGroupLabel(_ group: AppState.MajorVersionGroup) -> String {
        switch appState.selectedProduct {
        case .macOS:
            return "macOS \(group.major) \(group.name)"
        case .xcode:
            return "Xcode \(group.major)"
        }
    }

    private func groupCountLabel(for group: AppState.MajorVersionGroup) -> String {
        let total = group.releases.count
        let preRelease = group.releases.filter(\.isPrerelease).count
        let stable = total - preRelease
        if preRelease > 0 {
            return "\(stable) stable, \(preRelease) pre-release, \(total) total"
        }
        return "\(stable) stable"
    }

    private var totalCountLabel: String {
        let groups = appState.releasesByMajorVersion
        let total = groups.reduce(0) { $0 + $1.releases.count }
        let preRelease = groups.reduce(0) { $0 + $1.releases.filter(\.isPrerelease).count }
        let stable = total - preRelease
        if preRelease > 0 {
            return "\(stable) stable, \(preRelease) pre-release, \(total) total"
        }
        return "\(stable) stable"
    }

    private var productBinding: Binding<ProductType> {
        Binding(
            get: { appState.selectedProduct },
            set: { appState.switchProduct($0) }
        )
    }
}

// MARK: - Release Row

private struct ReleaseRow: View {
    let release: Release

    private var versionLabel: String {
        switch release.resolvedProductType {
        case .macOS: "macOS \(release.osVersion)"
        case .xcode: "Xcode \(release.osVersion)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(versionLabel)
                    .font(.body)
                    .fontWeight(.medium)

                if let betaLabel = release.betaLabel {
                    Text(betaLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                } else if let rcLabel = release.rcLabel {
                    Text(rcLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                }

                if release.isDeviceSpecific {
                    Text("Device Specific")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.indigo)
                }
            }

            HStack(spacing: 8) {
                Text(release.buildNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let date = release.releaseDate {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

        }
        .padding(.vertical, 2)
    }
}
