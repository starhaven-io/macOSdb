import Foundation

/// Kernelcaches can serve multiple chip tiers (e.g., a T6041/M4 Max kernel
/// runs on both M4 Pro and M4 Max Macs). This struct captures the resolved
/// per-device chip, as opposed to the kernel-level compilation target.
public struct DeviceChip: Codable, Hashable, Sendable {
    public let device: String
    public let chip: String

    public init(device: String, chip: String) {
        self.device = device
        self.chip = chip
    }
}

/// Each IPSW contains multiple kernelcache files, one per chip family,
/// with device model IDs encoded in the filename.
public struct KernelInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String { file }

    public let file: String
    public let darwinVersion: String
    public let xnuVersion: String?
    public let arch: String
    /// Kernel compilation target — either a marketing name ("M4 Max") or a raw
    /// identifier ("T8101"). This reflects the kernel target, not necessarily the
    /// chip in every device that runs this kernel.
    public let chip: String
    public let devices: [String]
    /// Per-device chip resolution (may differ from the kernel-level `chip` field).
    /// Nil for data files that predate this field.
    public let deviceChips: [DeviceChip]?

    public init(
        file: String,
        darwinVersion: String,
        xnuVersion: String? = nil,
        arch: String,
        chip: String,
        devices: [String],
        deviceChips: [DeviceChip]? = nil
    ) {
        self.file = file
        self.darwinVersion = darwinVersion
        self.xnuVersion = xnuVersion
        self.arch = arch
        self.chip = chip
        self.devices = devices
        self.deviceChips = deviceChips
    }

    public var isDevelopment: Bool {
        file.contains("kernelcache.development.")
    }

    /// Unique chip names from `deviceChips`, sorted by generation then tier
    /// (generation 0 sorts last). Falls back to the kernel-level `chip`.
    public var sortedChipNames: [String] {
        guard let deviceChips, !deviceChips.isEmpty else { return [chip] }
        return deviceChips
            .reduce(into: [String]()) { result, dc in
                if !result.contains(dc.chip) { result.append(dc.chip) }
            }
            .sorted { lhs, rhs in
                let lhsChip = ChipFamily.from(chipName: lhs)
                let rhsChip = ChipFamily.from(chipName: rhs)
                let lhsGen = lhsChip?.generation ?? 0
                let rhsGen = rhsChip?.generation ?? 0
                let lhsSortGen = lhsGen == 0 ? Int.max : lhsGen
                let rhsSortGen = rhsGen == 0 ? Int.max : rhsGen
                if lhsSortGen != rhsSortGen { return lhsSortGen < rhsSortGen }
                return (lhsChip?.tier ?? .base) < (rhsChip?.tier ?? .base)
            }
    }

    public var chipFamily: ChipFamily? {
        ChipFamily.from(chipName: chip)
    }

    /// Uses per-device resolution when available, falls back to the kernel-level chip.
    public var resolvedChipFamilies: [ChipFamily] {
        if let deviceChips, !deviceChips.isEmpty {
            var seen = Set<ChipFamily>()
            var result: [ChipFamily] = []
            for dc in deviceChips {
                if let family = ChipFamily.from(chipName: dc.chip), seen.insert(family).inserted {
                    result.append(family)
                }
            }
            return result
        }
        if let family = chipFamily {
            return [family]
        }
        return []
    }
}
