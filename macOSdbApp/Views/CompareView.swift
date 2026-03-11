import macOSdbKit
import SwiftUI

struct CompareView: View {
    @Environment(AppState.self)
    private var appState

    @State private var showOnlyChanged = true

    var body: some View {
        if let comparison = appState.comparison {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(comparison)
                    summaryBar(comparison)
                    changesTable(comparison)
                    addedSection(comparison)
                    removedSection(comparison)
                }
                .padding()
            }
            .navigationTitle("Compare")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ comparison: VersionComparison) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading) {
                Text("From")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("macOS \(comparison.from.osVersion)")
                    .font(.title2)
                    .fontWeight(.bold)
                Text(comparison.from.buildNumber)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "arrow.right")
                .font(.title)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading) {
                Text("To")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("macOS \(comparison.to.osVersion)")
                    .font(.title2)
                    .fontWeight(.bold)
                Text(comparison.to.buildNumber)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func summaryBar(_ comparison: VersionComparison) -> some View {
        HStack(spacing: 16) {
            SummaryBadge(
                count: comparison.upgradedComponents.count,
                label: "Upgraded",
                color: .green,
                icon: "arrow.up.circle.fill"
            )
            SummaryBadge(
                count: comparison.downgradedComponents.count,
                label: "Downgraded",
                color: .orange,
                icon: "arrow.down.circle.fill"
            )
            SummaryBadge(
                count: comparison.addedComponents.count,
                label: "Added",
                color: .blue,
                icon: "plus.circle.fill"
            )
            SummaryBadge(
                count: comparison.removedComponents.count,
                label: "Removed",
                color: .red,
                icon: "minus.circle.fill"
            )
        }
    }

    // MARK: - Changes Table

    @ViewBuilder
    private func changesTable(_ comparison: VersionComparison) -> some View {
        let items = showOnlyChanged ? comparison.changedComponents : comparison.changes

        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Components")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Toggle("Changed only", isOn: $showOnlyChanged)
                        .toggleStyle(.checkbox)
                }

                Table(items) {
                    TableColumn("Component") { (change: ComponentChange) in
                        Text(change.name)
                            .fontWeight(.medium)
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn(comparison.from.osVersion) { change in
                        Text(change.fromVersion)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 120)

                    TableColumn(comparison.to.osVersion) { change in
                        Text(change.toVersion)
                            .foregroundStyle(colorForDirection(change.direction))
                    }
                    .width(min: 80, ideal: 120)

                    TableColumn("") { change in
                        Image(systemName: iconForDirection(change.direction))
                            .foregroundStyle(colorForDirection(change.direction))
                    }
                    .width(30)
                }
                .frame(minHeight: 300)
            }
        }
    }

    // MARK: - Added/Removed

    @ViewBuilder
    private func addedSection(_ comparison: VersionComparison) -> some View {
        if !comparison.addedComponents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Added Components")
                    .font(.title3)
                    .fontWeight(.semibold)

                ForEach(comparison.addedComponents) { comp in
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                        Text(comp.name)
                            .fontWeight(.medium)
                        Spacer()
                        Text(comp.displayVersion)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    @ViewBuilder
    private func removedSection(_ comparison: VersionComparison) -> some View {
        if !comparison.removedComponents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Removed Components")
                    .font(.title3)
                    .fontWeight(.semibold)

                ForEach(comparison.removedComponents) { comp in
                    HStack {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                        Text(comp.name)
                            .fontWeight(.medium)
                        Spacer()
                        Text(comp.displayVersion)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Helpers

    private func colorForDirection(_ direction: ChangeDirection) -> Color {
        switch direction {
        case .upgraded: .green
        case .downgraded: .orange
        case .unchanged: .secondary
        }
    }

    private func iconForDirection(_ direction: ChangeDirection) -> String {
        switch direction {
        case .upgraded: "arrow.up.circle.fill"
        case .downgraded: "arrow.down.circle.fill"
        case .unchanged: "equal.circle"
        }
    }
}

// MARK: - Summary Badge

private struct SummaryBadge: View {
    let count: Int
    let label: String
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)")
                    .font(.headline)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
