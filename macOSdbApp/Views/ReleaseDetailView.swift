import macOSdbKit
import SwiftUI

struct ReleaseDetailView: View {
    @Environment(AppState.self)
    private var appState

    @State private var sortOrder = [KeyPathComparator(\Component.name)]

    var body: some View {
        if let release = appState.selectedRelease {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    releaseHeader(release)
                    if let sdks = release.sdks, !sdks.isEmpty {
                        sdkSection(sdks)
                    }
                    componentTable(release)
                    if !release.kernels.isEmpty {
                        kernelSection(release)
                    }
                    if release.resolvedProductType == .macOS {
                        chipSection(release)
                    }
                }
                .padding()
            }
            .navigationTitle(release.displayName)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func releaseHeader(_ release: Release) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(release.displayName)
                .font(.largeTitle)
                .fontWeight(.bold)

            HStack(spacing: 16) {
                Label(release.buildNumber, systemImage: "number")
                if let date = release.releaseDate {
                    Label(date, systemImage: "calendar")
                }
                Label(
                    "\(release.components.count) components",
                    systemImage: "shippingbox"
                )
                if release.resolvedProductType == .macOS {
                    Label(
                        "\(release.supportedChips.count) chip families",
                        systemImage: "cpu"
                    )
                }
                if let minOS = release.minimumOSVersion {
                    Label("Requires macOS \(minOS)", systemImage: "exclamationmark.triangle")
                }
                if release.isDeviceSpecific {
                    Label("Device Specific", systemImage: "desktopcomputer")
                }
                if let urlString = release.ipswURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                if let urlString = release.xipURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - SDK Info

    @ViewBuilder
    private func sdkSection(_ sdks: [SDKInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS SDKs")
                .font(.title2)
                .fontWeight(.semibold)

            ForEach(sdks) { sdk in
                Label(sdkLabel(sdk), systemImage: "sdcard")
                    .font(.headline)
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func sdkLabel(_ sdk: SDKInfo) -> String {
        if let build = sdk.buildVersion {
            return "SDK \(sdk.sdkVersion) (\(build))"
        }
        return "SDK \(sdk.sdkVersion)"
    }

    // MARK: - Components

    @ViewBuilder
    private func componentTable(_ release: Release) -> some View {
        let filtered = filteredComponents(release).sorted(using: sortOrder)

        VStack(alignment: .leading, spacing: 8) {
            Text("Components")
                .font(.title2)
                .fontWeight(.semibold)

            if filtered.isEmpty {
                ContentUnavailableView.search(text: appState.searchText)
            } else {
                Table(filtered, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { comp in
                        Text(comp.name)
                            .fontWeight(.medium)
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Version") { comp in
                        Text(comp.displayVersion)
                    }
                    .width(min: 80, ideal: 120)

                    TableColumn("Path", value: \.path) { comp in
                        Text(comp.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 150, ideal: 250)
                }
                .frame(minHeight: 300)
            }
        }
    }

    // MARK: - Kernel

    @ViewBuilder
    private func kernelSection(_ release: Release) -> some View {
        let grouped = groupKernels(release.kernels).sorted { lhs, rhs in
            if lhs.isDevelopment != rhs.isDevelopment { return !lhs.isDevelopment }
            let lhsOrder = lhs.chipFamily?.series.sortOrder ?? -1
            let rhsOrder = rhs.chipFamily?.series.sortOrder ?? -1
            if lhsOrder != rhsOrder { return lhsOrder > rhsOrder }
            let lhsTier = lhs.chipFamily?.tier ?? .base
            let rhsTier = rhs.chipFamily?.tier ?? .base
            return lhsTier < rhsTier
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Kernel")
                .font(.title2)
                .fontWeight(.semibold)

            ForEach(grouped) { kernel in
                KernelCard(kernel: kernel)
            }
        }
    }

    // MARK: - Chips

    @ViewBuilder
    private func chipSection(_ release: Release) -> some View {
        if !release.supportedChips.isEmpty {
            ChipSupportView(kernels: release.kernels, chips: release.supportedChips)
        }
    }

    // MARK: - Helpers

    private func filteredComponents(_ release: Release) -> [Component] {
        let searchText = appState.searchText.trimmingCharacters(in: .whitespaces)
        guard !searchText.isEmpty else { return release.components }

        return release.components.filter { comp in
            comp.name.localizedCaseInsensitiveContains(searchText)
                || comp.displayVersion.localizedCaseInsensitiveContains(searchText)
                || comp.path.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Kernel Grouping

private struct GroupedKernel: Identifiable {
    var id: String { "\(chip)-\(arch)-\(darwinVersion)-\(xnuVersion ?? "")" }

    let chip: String
    let darwinVersion: String
    let xnuVersion: String?
    let arch: String
    let files: [String]
    let devices: [String]
    let deviceChips: [DeviceChip]?
    let isDevelopment: Bool

    var chipFamily: ChipFamily? { ChipFamily.from(chipName: chip) }

    var sortedChipNames: [String] {
        guard let deviceChips, !deviceChips.isEmpty else { return [chip] }
        let families = deviceChips.compactMap { ChipFamily.from(chipName: $0.chip) }
        guard !families.isEmpty else { return [chip] }
        let unique = Dictionary(grouping: families, by: { $0.displayName }).values.compactMap(\.first)
        return unique
            .sorted { lhs, rhs in
                if lhs.series.sortOrder != rhs.series.sortOrder {
                    return lhs.series.sortOrder > rhs.series.sortOrder
                }
                return lhs.tier < rhs.tier
            }
            .map { $0.displayName }
    }
}

private func groupKernels(_ kernels: [KernelInfo]) -> [GroupedKernel] {
    var groups: [String: GroupedKernel] = [:]
    var order: [String] = []

    for kernel in kernels {
        let key = "\(kernel.chip)-\(kernel.arch)-\(kernel.darwinVersion)-\(kernel.xnuVersion ?? "")"
        if var existing = groups[key] {
            var files = existing.files
            files.append(kernel.file)
            var devices = existing.devices
            for device in kernel.devices where !devices.contains(device) {
                devices.append(device)
            }
            var deviceChips = existing.deviceChips ?? []
            for dc in kernel.deviceChips ?? [] where !deviceChips.contains(dc) {
                deviceChips.append(dc)
            }
            existing = GroupedKernel(
                chip: existing.chip,
                darwinVersion: existing.darwinVersion,
                xnuVersion: existing.xnuVersion,
                arch: existing.arch,
                files: files,
                devices: devices,
                deviceChips: deviceChips.isEmpty ? nil : deviceChips,
                isDevelopment: existing.isDevelopment || kernel.isDevelopment
            )
            groups[key] = existing
        } else {
            order.append(key)
            groups[key] = GroupedKernel(
                chip: kernel.chip,
                darwinVersion: kernel.darwinVersion,
                xnuVersion: kernel.xnuVersion,
                arch: kernel.arch,
                files: [kernel.file],
                devices: kernel.devices,
                deviceChips: kernel.deviceChips,
                isDevelopment: kernel.isDevelopment
            )
        }
    }

    return order.compactMap { groups[$0] }
}

// MARK: - Kernel Card

private struct KernelCard: View {
    let kernel: GroupedKernel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(kernel.sortedChipNames.joined(separator: ", "))
                        .font(.headline)
                    if kernel.isDevelopment {
                        Text("Development")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Darwin \(kernel.darwinVersion)")
                    .font(.callout)
                if let xnuVersion = kernel.xnuVersion {
                    Text("XNU \(xnuVersion)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(kernel.files.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(kernel.arch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    kernel.devices
                        .map { DeviceRegistry.info(for: $0)?.marketingName ?? $0 }
                        .joined(separator: ", ")
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
