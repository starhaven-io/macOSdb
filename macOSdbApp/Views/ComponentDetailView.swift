import macOSdbKit
import SwiftUI

struct ComponentDetailView: View {
    @Environment(AppState.self)
    private var appState

    let componentName: String

    private var component: AppState.ComponentSummary? {
        appState.allComponents.first { $0.name == componentName }
    }

    var body: some View {
        if let component {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    componentHeader(component)
                    versionHistorySection
                }
                .padding()
            }
            .navigationTitle(componentName)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func componentHeader(_ component: AppState.ComponentSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(component.name)
                .font(.largeTitle)
                .fontWeight(.bold)

            HStack(spacing: 16) {
                Label(component.latestVersion, systemImage: "tag")
                Label(component.source.rawValue, systemImage: "archivebox")
                Label(component.path, systemImage: "folder")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Version History

    @ViewBuilder private var versionHistorySection: some View {
        let history = appState.componentHistory(for: componentName)

        VStack(alignment: .leading, spacing: 8) {
            Text("Version History")
                .font(.title2)
                .fontWeight(.semibold)

            Text("\(history.count) version\(history.count == 1 ? "" : "s") tracked")
                .font(.callout)
                .foregroundStyle(.secondary)

            if history.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("No version changes found for this component.")
                )
            } else {
                versionTable(history)
            }
        }
    }

    @ViewBuilder
    private func versionTable(_ history: [AppState.ComponentVersionEntry]) -> some View {
        Table(history) {
            TableColumn("Version") { entry in
                Text(entry.version)
                    .fontDesign(.monospaced)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Introduced In") { entry in
                HStack(spacing: 6) {
                    Text(entry.releaseName)
                    if entry.isBeta {
                        Text("Beta")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    } else if entry.isRC {
                        Text("RC")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                    }
                }
            }
            .width(min: 150, ideal: 200)

            TableColumn("Date") { entry in
                Text(entry.releaseDate ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Status") { entry in
                StatusLabel(direction: entry.direction)
            }
            .width(min: 80, ideal: 110)
        }
        .frame(minHeight: 300)
    }
}

// MARK: - Status Label

private struct StatusLabel: View {
    let direction: ChangeDirection?

    var body: some View {
        switch direction {
        case .upgraded:
            Label("Upgraded", systemImage: "arrow.up.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .downgraded:
            Label("Downgraded", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .unchanged:
            EmptyView()
        case nil:
            Label("First tracked", systemImage: "plus.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        }
    }
}
