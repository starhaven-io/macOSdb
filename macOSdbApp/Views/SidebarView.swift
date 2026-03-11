import macOSdbKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self)
    private var appState

    @State private var expandedGroups: Set<Int> = []
    @State private var hasInitializedExpansion = false

    var body: some View {
        @Bindable var state = appState

        List(selection: appState.isComparing ? compareBinding : selectionBinding) {
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
                        Text("macOS \(group.major) \(group.name)")
                            .font(.callout)
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
        .listStyle(.sidebar)
        .navigationTitle("macOSdb")
        .safeAreaInset(edge: .bottom) {
            if appState.isComparing {
                Text("Select a release to compare with")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            } else {
                Toggle("Show pre-releases", isOn: showBetasBinding)
                    .toggleStyle(.checkbox)
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

    private var selectionBinding: Binding<Release?> {
        Binding(
            get: { appState.selectedRelease },
            set: { appState.selectedRelease = $0 }
        )
    }

    private var compareBinding: Binding<Release?> {
        Binding(
            get: { appState.compareRelease },
            set: { appState.compareRelease = $0 }
        )
    }

    private var showBetasBinding: Binding<Bool> {
        Binding(
            get: { appState.showBetas },
            set: { appState.showBetas = $0 }
        )
    }
}

// MARK: - Release Row

private struct ReleaseRow: View {
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("macOS \(release.osVersion)")
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
                        .foregroundStyle(.mint)
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
