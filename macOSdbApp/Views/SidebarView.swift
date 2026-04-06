import macOSdbKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self)
    private var appState

    @State private var expandedGroups: Set<Int> = []
    @State private var hasInitializedExpansion = false

    var body: some View {
        @Bindable var state = appState

        Group {
            switch appState.sidebarMode {
            case .releases:
                releaseList
            case .components:
                componentList
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("macOSdb")
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                Picker("Product", selection: productBinding) {
                    ForEach(ProductType.allCases, id: \.self) { product in
                        Text(product.displayName).tag(product)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("Mode", selection: $state.sidebarMode) {
                    ForEach(AppState.SidebarMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
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
                    if appState.sidebarMode == .releases {
                        Toggle("Show device specific", isOn: $state.showDeviceSpecific)
                            .toggleStyle(.checkbox)
                    }
                    Text(bottomCountLabel)
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

    // MARK: - Release List

    private var releaseList: some View {
        @Bindable var state = appState

        return List(selection: appState.isComparing ? $state.compareRelease : $state.selectedRelease) {
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
    }

    // MARK: - Component List

    private var componentList: some View {
        @Bindable var state = appState

        return List(selection: $state.selectedComponentName) {
            if appState.isLoading && appState.releases.isEmpty {
                ProgressView("Loading releases...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if appState.filteredComponents.isEmpty {
                if appState.searchText.isEmpty {
                    ContentUnavailableView(
                        "No Components",
                        systemImage: "shippingbox",
                        description: Text("No component data available.")
                    )
                } else {
                    ContentUnavailableView.search(text: appState.searchText)
                }
            } else {
                ForEach(appState.filteredComponents) { comp in
                    ComponentRow(component: comp)
                        .tag(comp.name)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
            }
        }
        .id(appState.selectedProduct)
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

    private var bottomCountLabel: String {
        switch appState.sidebarMode {
        case .releases:
            let groups = appState.releasesByMajorVersion
            let total = groups.reduce(0) { $0 + $1.releases.count }
            let preRelease = groups.reduce(0) { $0 + $1.releases.filter(\.isPrerelease).count }
            let stable = total - preRelease
            if preRelease > 0 {
                return "\(stable) stable, \(preRelease) pre-release, \(total) total"
            }
            return "\(stable) stable"
        case .components:
            let count = appState.filteredComponents.count
            let total = appState.allComponents.count
            if count != total {
                return "\(count) of \(total) components"
            }
            return "\(total) components"
        }
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

// MARK: - Component Row

private struct ComponentRow: View {
    let component: AppState.ComponentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(component.name)
                .font(.body)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                Text(component.latestVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(component.source.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
