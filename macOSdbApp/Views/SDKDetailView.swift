import macOSdbKit
import SwiftUI

struct SDKDetailView: View {
    @Environment(AppState.self)
    private var appState

    let sdkVersion: String

    private var summary: AppState.SDKSummary? {
        appState.allSDKs.first { $0.version == sdkVersion }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                historySection
            }
            .padding()
        }
        .navigationTitle("macOS SDK \(sdkVersion)")
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS SDK \(sdkVersion)")
                .font(.largeTitle)
                .fontWeight(.bold)

            HStack(spacing: 16) {
                if let build = summary?.latestBuild {
                    Label(build, systemImage: "number")
                }
                if let count = summary?.xcodeReleaseCount {
                    Label(
                        "\(count) Xcode release\(count == 1 ? "" : "s")",
                        systemImage: "hammer"
                    )
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - History

    @ViewBuilder private var historySection: some View {
        let history = appState.sdkHistory(for: sdkVersion)

        VStack(alignment: .leading, spacing: 8) {
            Text("Releases")
                .font(.title2)
                .fontWeight(.semibold)

            Text("\(history.count) Xcode release\(history.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)

            if history.isEmpty {
                ContentUnavailableView(
                    "No Releases",
                    systemImage: "clock",
                    description: Text("No Xcode releases shipped this SDK version.")
                )
            } else {
                historyTable(history)
            }
        }
    }

    @ViewBuilder
    private func historyTable(_ history: [AppState.SDKVersionEntry]) -> some View {
        Table(history) {
            TableColumn("SDK Build") { entry in
                HStack(spacing: 6) {
                    Text(entry.sdkBuild ?? "—")
                        .fontDesign(.monospaced)
                    if entry.isFirstShippingBuild {
                        Text("New")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                    }
                }
            }
            .width(min: 100, ideal: 140)

            TableColumn("Xcode Release") { entry in
                HStack(spacing: 6) {
                    Text(entry.xcodeDisplayName)
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
            .width(min: 180, ideal: 240)

            TableColumn("Xcode Build") { entry in
                Text(entry.xcodeBuild)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Date") { entry in
                Text(entry.xcodeReleaseDate ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
        }
        .frame(minHeight: 300)
    }
}
