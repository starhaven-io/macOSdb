/// Apple Silicon chip families, mapped from ARM64 target suffixes in kernelcache builds.
///
/// The mapping is derived from the architecture suffix in kernel version strings
/// (e.g. `RELEASE_ARM64_T8132` → M4).
package enum ChipFamily: String, CaseIterable, Sendable, Codable {
    case a12z
    case a18Pro
    case m1
    case m1Pro
    case m1Max
    case m1Ultra
    case m2
    case m2Pro
    case m2Max
    case m2Ultra
    case m3
    case m3Pro
    case m3Max
    case m3Ultra
    case m4
    case m4Pro
    case m4Max
    case m4Ultra
    case m5
    case m5Pro
    case m5Max
    case m5Ultra
    case virtualMac

    package var displayName: String {
        switch self {
        case .a12z: "A12Z (DTK)"
        case .a18Pro: "A18 Pro"
        case .m1: "M1"
        case .m1Pro: "M1 Pro"
        case .m1Max: "M1 Max"
        case .m1Ultra: "M1 Ultra"
        case .m2: "M2"
        case .m2Pro: "M2 Pro"
        case .m2Max: "M2 Max"
        case .m2Ultra: "M2 Ultra"
        case .m3: "M3"
        case .m3Pro: "M3 Pro"
        case .m3Max: "M3 Max"
        case .m3Ultra: "M3 Ultra"
        case .m4: "M4"
        case .m4Pro: "M4 Pro"
        case .m4Max: "M4 Max"
        case .m4Ultra: "M4 Ultra"
        case .m5: "M5"
        case .m5Pro: "M5 Pro"
        case .m5Max: "M5 Max"
        case .m5Ultra: "M5 Ultra"
        case .virtualMac: "Virtual Mac"
        }
    }

    package var tier: ChipTier {
        switch self {
        case .a12z: .base
        case .a18Pro: .pro
        case .m1, .m2, .m3, .m4, .m5: .base
        case .m1Pro, .m2Pro, .m3Pro, .m4Pro, .m5Pro: .pro
        case .m1Max, .m2Max, .m3Max, .m4Max, .m5Max: .max
        case .m1Ultra, .m2Ultra, .m3Ultra, .m4Ultra, .m5Ultra: .ultra
        case .virtualMac: .base
        }
    }

    /// Maps the suffix after `RELEASE_ARM64_` (e.g. "T8103", "T6041") to a chip family.
    package static func from(archSuffix: String) -> Self? { // swiftlint:disable:this cyclomatic_complexity
        switch archSuffix {
        // A12Z — Developer Transition Kit (macOS 11 only)
        case "T8020": .a12z
        // A18 Pro — MacBook Neo (first A-series chip in a shipping Mac)
        case "T8140": .a18Pro
        // M1 family — T8101 is the A14-derived ID used in macOS 11–12 kernelcaches
        case "T8101", "T8103": .m1
        case "T6000": .m1Pro
        case "T6001": .m1Max
        case "T6002": .m1Ultra
        // M2 family — T8110 is the A15-derived ID used in macOS 12 kernelcaches
        case "T8110", "T8112": .m2
        case "T6020": .m2Pro
        case "T6021": .m2Max
        case "T6022": .m2Ultra
        // M3 family — T6034 is a second M3 Max die variant alongside T6031
        case "T8122": .m3
        case "T6030": .m3Pro
        case "T6031", "T6034": .m3Max
        case "T6032": .m3Ultra
        // M4 family — T6042 (M4 Ultra) was never released; kept for completeness
        case "T8132": .m4
        case "T6040": .m4Pro
        case "T6041": .m4Max
        case "T6042": .m4Ultra
        // M5 family
        case "T8142": .m5
        case "T6050": .m5Pro
        case "T6051": .m5Max
        case "T6052": .m5Ultra
        case "VMAPPLE": .virtualMac
        default: nil
        }
    }

    package static func from(chipName: String) -> Self? {
        allCases.first { $0.displayName == chipName }
    }
}

package enum ChipTier: String, Codable, Sendable, Comparable {
    case base
    case pro
    case max
    case ultra

    package static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.base, .pro, .max, .ultra]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else { return false }
        return lhsIndex < rhsIndex
    }
}
