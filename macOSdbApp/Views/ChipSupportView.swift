import macOSdbKit
import SwiftUI

struct ChipSupportView: View {
    let kernels: [KernelInfo]
    let chips: [ChipFamily]

    private let gridColumns = [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardware Support")
                .font(.title2)
                .fontWeight(.semibold)

            ForEach(generationGroups, id: \.generation) { genGroup in
                VStack(alignment: .leading, spacing: 8) {
                    Text(genGroup.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                        ForEach(genGroup.chips, id: \.chip) { group in
                            ChipCard(chip: group.chip, devices: group.devices, arch: group.arch)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
            }
        }
    }

    private struct ChipGroup {
        let chip: ChipFamily
        var devices: [String]
        let arch: String
    }

    private struct GenerationGroup {
        let generation: Int
        let label: String
        let chips: [ChipGroup]
    }

    private var generationGroups: [GenerationGroup] {
        let sorted = chipGroups.sorted { lhs, rhs in
            if lhs.chip.generation != rhs.chip.generation {
                return lhs.chip.generation > rhs.chip.generation
            }
            return lhs.chip.tier < rhs.chip.tier
        }

        var result: [GenerationGroup] = []
        for group in sorted {
            let gen = group.chip.generation
            if let index = result.firstIndex(where: { $0.generation == gen }) {
                result[index] = GenerationGroup(
                    generation: gen,
                    label: result[index].label,
                    chips: result[index].chips + [group]
                )
            } else {
                let label = gen == 0 ? "Other" : "Apple M\(gen) Series"
                result.append(GenerationGroup(generation: gen, label: label, chips: [group]))
            }
        }
        return result
    }

    /// Group devices by their actual chip family. Uses per-device resolution
    /// from `deviceChips` when available, then falls back to `DeviceRegistry`
    /// lookups, and finally to the kernel-level chip label.
    private var chipGroups: [ChipGroup] {
        var groups: [ChipGroup] = []

        for kernel in kernels {
            if let deviceChips = kernel.deviceChips, !deviceChips.isEmpty {
                for dc in deviceChips {
                    guard let chip = ChipFamily.from(chipName: dc.chip) else { continue }
                    if let index = groups.firstIndex(where: { $0.chip == chip }) {
                        if !groups[index].devices.contains(dc.device) {
                            groups[index].devices.append(dc.device)
                        }
                    } else {
                        groups.append(ChipGroup(chip: chip, devices: [dc.device], arch: kernel.arch))
                    }
                }
            } else {
                let kernelChip = ChipFamily.from(chipName: kernel.chip)
                for device in kernel.devices {
                    let chip = DeviceRegistry.chip(for: device) ?? kernelChip
                    guard let chip else { continue }
                    if let index = groups.firstIndex(where: { $0.chip == chip }) {
                        if !groups[index].devices.contains(device) {
                            groups[index].devices.append(device)
                        }
                    } else {
                        groups.append(ChipGroup(chip: chip, devices: [device], arch: kernel.arch))
                    }
                }
            }
        }

        return groups.map { group in
            ChipGroup(chip: group.chip, devices: group.devices.sorted(), arch: group.arch)
        }
    }
}

// MARK: - Chip Card

private struct ChipCard: View {
    let chip: ChipFamily
    let devices: [String]
    let arch: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(chip.displayName)
                    .font(.headline)
                Spacer()
            }

            Text(arch)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                ForEach(devices, id: \.self) { device in
                    Text(device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
