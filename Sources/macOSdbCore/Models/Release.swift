import Foundation

/// A release with its extracted open source component versions.
///
/// Supports macOS (IPSW firmware) and Xcode (.xip).
package struct Release: Codable, Identifiable, Hashable, Sendable {
    package var id: String { buildNumber }

    enum CodingKeys: String, CodingKey {
        case productType, osVersion, buildNumber, releaseName, releaseDate
        case ipswFile, ipswURL, xipFile, xipURL
        case isBeta, betaNumber, isRC, rcNumber, isDeviceSpecific
        case kernels, components, sdks, minimumOSVersion
    }

    package let productType: ProductType?
    package let osVersion: String
    package let buildNumber: String
    package let releaseName: String
    package let releaseDate: String?
    package let ipswFile: String?
    package let ipswURL: String?
    package let xipFile: String?
    package let xipURL: String?
    package let isBeta: Bool
    package let betaNumber: Int?
    package let isRC: Bool
    package let rcNumber: Int?
    package let isDeviceSpecific: Bool
    package let kernels: [KernelInfo]
    package let components: [Component]
    package let sdks: [SDKInfo]?
    package let minimumOSVersion: String?

    package init(
        productType: ProductType? = .macOS,
        osVersion: String,
        buildNumber: String,
        releaseName: String,
        releaseDate: String? = nil,
        ipswFile: String? = nil,
        ipswURL: String? = nil,
        xipFile: String? = nil,
        xipURL: String? = nil,
        isBeta: Bool = false,
        betaNumber: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil,
        isDeviceSpecific: Bool = false,
        kernels: [KernelInfo] = [],
        components: [Component] = [],
        sdks: [SDKInfo]? = nil,
        minimumOSVersion: String? = nil
    ) {
        self.productType = productType
        self.osVersion = osVersion
        self.buildNumber = buildNumber
        self.releaseName = releaseName
        self.releaseDate = releaseDate
        self.ipswFile = ipswFile
        self.ipswURL = ipswURL
        self.xipFile = xipFile
        self.xipURL = xipURL
        self.isBeta = isBeta
        self.betaNumber = betaNumber
        self.isRC = isRC
        self.rcNumber = rcNumber
        self.isDeviceSpecific = isDeviceSpecific
        self.kernels = kernels
        self.components = components
        self.sdks = sdks
        self.minimumOSVersion = minimumOSVersion
    }

    package var majorVersion: Int {
        let parts = osVersion.split(separator: ".")
        return Int(parts.first ?? "") ?? 0
    }

    package var minorVersion: Int {
        let parts = osVersion.split(separator: ".")
        guard parts.count > 1 else { return 0 }
        return Int(parts[1]) ?? 0
    }

    package var patchVersion: Int {
        let parts = osVersion.split(separator: ".")
        guard parts.count > 2 else { return 0 }
        return Int(parts[2]) ?? 0
    }

    /// Derived from per-device chip resolution when available, falling back to kernel-level chip labels.
    package var supportedChips: [ChipFamily] {
        var seen = Set<ChipFamily>()
        var result: [ChipFamily] = []
        for kernel in kernels {
            for family in kernel.resolvedChipFamilies where seen.insert(family).inserted {
                result.append(family)
            }
        }
        return result
    }

    /// The resolved product type, defaulting to `.macOS` for backward compatibility with existing JSON.
    package var resolvedProductType: ProductType {
        productType ?? .macOS
    }

    package var displayName: String {
        let prefix: String
        switch resolvedProductType {
        case .macOS:
            prefix = "macOS \(osVersion) \(releaseName)"
        case .xcode:
            prefix = "Xcode \(osVersion)"
        }
        if let betaLabel {
            return "\(prefix) \(betaLabel)"
        }
        return prefix
    }

    package func component(named name: String) -> Component? {
        components.first { $0.name.lowercased() == name.lowercased() }
    }

    package func withComponents(_ components: [Component]) -> Self {
        Self(
            productType: productType,
            osVersion: osVersion,
            buildNumber: buildNumber,
            releaseName: releaseName,
            releaseDate: releaseDate,
            ipswFile: ipswFile,
            ipswURL: ipswURL,
            xipFile: xipFile,
            xipURL: xipURL,
            isBeta: isBeta,
            betaNumber: betaNumber,
            isRC: isRC,
            rcNumber: rcNumber,
            isDeviceSpecific: isDeviceSpecific,
            kernels: kernels,
            components: components,
            sdks: sdks,
            minimumOSVersion: minimumOSVersion
        )
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productType = try container.decodeIfPresent(ProductType.self, forKey: .productType)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        releaseName = try container.decode(String.self, forKey: .releaseName)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        ipswFile = try container.decodeIfPresent(String.self, forKey: .ipswFile)
        ipswURL = try container.decodeIfPresent(String.self, forKey: .ipswURL)
        xipFile = try container.decodeIfPresent(String.self, forKey: .xipFile)
        xipURL = try container.decodeIfPresent(String.self, forKey: .xipURL)
        isBeta = try container.decodeIfPresent(Bool.self, forKey: .isBeta) ?? false
        betaNumber = try container.decodeIfPresent(Int.self, forKey: .betaNumber)
        isRC = try container.decodeIfPresent(Bool.self, forKey: .isRC) ?? false
        rcNumber = try container.decodeIfPresent(Int.self, forKey: .rcNumber)
        isDeviceSpecific = try container.decodeIfPresent(Bool.self, forKey: .isDeviceSpecific) ?? false
        kernels = try container.decodeIfPresent([KernelInfo].self, forKey: .kernels) ?? []
        components = try container.decodeIfPresent([Component].self, forKey: .components) ?? []
        sdks = try container.decodeIfPresent([SDKInfo].self, forKey: .sdks)
        minimumOSVersion = try container.decodeIfPresent(String.self, forKey: .minimumOSVersion)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(productType, forKey: .productType)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(buildNumber, forKey: .buildNumber)
        try container.encode(releaseName, forKey: .releaseName)
        try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try container.encodeIfPresent(ipswFile, forKey: .ipswFile)
        try container.encodeIfPresent(ipswURL, forKey: .ipswURL)
        try container.encodeIfPresent(xipFile, forKey: .xipFile)
        try container.encodeIfPresent(xipURL, forKey: .xipURL)
        try container.encode(isBeta, forKey: .isBeta)
        try container.encodeIfPresent(betaNumber, forKey: .betaNumber)
        try container.encode(isRC, forKey: .isRC)
        try container.encodeIfPresent(rcNumber, forKey: .rcNumber)
        if productType != .xcode {
            try container.encode(isDeviceSpecific, forKey: .isDeviceSpecific)
        }
        if !kernels.isEmpty {
            try container.encode(kernels, forKey: .kernels)
        }
        try container.encode(components, forKey: .components)
        try container.encodeIfPresent(sdks, forKey: .sdks)
        try container.encodeIfPresent(minimumOSVersion, forKey: .minimumOSVersion)
    }
}

extension Release {
    /// Display label for beta releases, e.g. "Developer Beta 3" or "Beta".
    package var betaLabel: String? {
        guard isBeta else { return nil }
        if let betaNumber {
            return "Developer Beta \(betaNumber)"
        }
        return "Beta"
    }
}

/// An entry in the release index file (`releases.json`).
package struct ReleaseIndexEntry: Codable, Identifiable, Hashable, Sendable {
    package var id: String { buildNumber }

    enum CodingKeys: String, CodingKey {
        case productType, osVersion, buildNumber, releaseName, releaseDate
        case isBeta, betaNumber, isRC, rcNumber, isDeviceSpecific
        case dataFile
    }

    package let productType: ProductType?
    package let osVersion: String
    package let buildNumber: String
    package let releaseName: String
    package let releaseDate: String?
    package let isBeta: Bool
    package let betaNumber: Int?
    package let isRC: Bool
    package let rcNumber: Int?
    package let isDeviceSpecific: Bool
    package let dataFile: String

    /// The resolved product type, defaulting to `.macOS` for backward compatibility with existing JSON.
    package var resolvedProductType: ProductType {
        productType ?? .macOS
    }

    package init(
        productType: ProductType? = .macOS,
        osVersion: String,
        buildNumber: String,
        releaseName: String,
        releaseDate: String? = nil,
        isBeta: Bool = false,
        betaNumber: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil,
        isDeviceSpecific: Bool = false,
        dataFile: String
    ) {
        self.productType = productType
        self.osVersion = osVersion
        self.buildNumber = buildNumber
        self.releaseName = releaseName
        self.releaseDate = releaseDate
        self.isBeta = isBeta
        self.betaNumber = betaNumber
        self.isRC = isRC
        self.rcNumber = rcNumber
        self.isDeviceSpecific = isDeviceSpecific
        self.dataFile = dataFile
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productType = try container.decodeIfPresent(ProductType.self, forKey: .productType)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        releaseName = try container.decode(String.self, forKey: .releaseName)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        isBeta = try container.decodeIfPresent(Bool.self, forKey: .isBeta) ?? false
        betaNumber = try container.decodeIfPresent(Int.self, forKey: .betaNumber)
        isRC = try container.decodeIfPresent(Bool.self, forKey: .isRC) ?? false
        rcNumber = try container.decodeIfPresent(Int.self, forKey: .rcNumber)
        isDeviceSpecific = try container.decodeIfPresent(Bool.self, forKey: .isDeviceSpecific) ?? false
        dataFile = try container.decode(String.self, forKey: .dataFile)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(productType, forKey: .productType)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(buildNumber, forKey: .buildNumber)
        try container.encode(releaseName, forKey: .releaseName)
        try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try container.encode(isBeta, forKey: .isBeta)
        try container.encodeIfPresent(betaNumber, forKey: .betaNumber)
        try container.encode(isRC, forKey: .isRC)
        try container.encodeIfPresent(rcNumber, forKey: .rcNumber)
        if resolvedProductType != .xcode {
            try container.encode(isDeviceSpecific, forKey: .isDeviceSpecific)
        }
        try container.encode(dataFile, forKey: .dataFile)
    }

    package static func versionAscending(_ lhs: Self, _ rhs: Self) -> Bool {
        ReleaseOrdering.versionAscending(lhs, rhs)
    }

    package static func versionDescending(_ lhs: Self, _ rhs: Self) -> Bool {
        versionAscending(rhs, lhs)
    }
}

extension Release: ReleaseOrderingFields {}

extension ReleaseIndexEntry: ReleaseOrderingFields {}

extension Release: Comparable {
    package static func < (lhs: Release, rhs: Release) -> Bool {
        ReleaseOrdering.versionAscending(lhs, rhs)
    }
}

private protocol ReleaseOrderingFields {
    var osVersion: String { get }
    var buildNumber: String { get }
    var isBeta: Bool { get }
    var betaNumber: Int? { get }
    var isRC: Bool { get }
    var rcNumber: Int? { get }
}

private enum ReleaseOrdering {
    static func versionAscending<LHS: ReleaseOrderingFields, RHS: ReleaseOrderingFields>(
        _ lhs: LHS,
        _ rhs: RHS
    ) -> Bool {
        let lhsVersion = versionParts(lhs.osVersion)
        let rhsVersion = versionParts(rhs.osVersion)
        if lhsVersion.major != rhsVersion.major {
            return lhsVersion.major < rhsVersion.major
        }
        if lhsVersion.minor != rhsVersion.minor {
            return lhsVersion.minor < rhsVersion.minor
        }
        if lhsVersion.patch != rhsVersion.patch {
            return lhsVersion.patch < rhsVersion.patch
        }
        let lhsRank = prereleaseRank(lhs)
        let rhsRank = prereleaseRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return BuildNumber.less(lhs.buildNumber, rhs.buildNumber)
    }

    private static func versionParts(_ osVersion: String) -> (major: Int, minor: Int, patch: Int) {
        let parts = osVersion.split(separator: ".")
        let major = Int(parts.first ?? "") ?? 0
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        return (major, minor, patch)
    }

    private static func prereleaseRank<T: ReleaseOrderingFields>(_ release: T) -> (Int, Int) {
        if release.isBeta { return (0, release.betaNumber ?? 0) }
        if release.isRC { return (1, release.rcNumber ?? 0) }
        return (2, 0)
    }
}

package enum BuildNumber {
    /// Apple beta build numbers end with a lowercase letter (e.g. `25E5207k`),
    /// while release builds end with a digit (e.g. `24G90`).
    static func isBeta(_ buildNumber: String) -> Bool {
        guard let last = buildNumber.last else { return false }
        return last.isLetter && last.isLowercase
    }

    /// Orders Apple build numbers by (cycle, train, build, suffix) so re-release
    /// variants compare numerically (24B83 < 24B2083) rather than lexicographically
    /// (where "24B2083" < "24B83" because '2' < '8').
    package static func less(_ lhs: String, _ rhs: String) -> Bool {
        let lhsParts = parse(lhs), rhsParts = parse(rhs)
        if lhsParts.cycle != rhsParts.cycle { return lhsParts.cycle < rhsParts.cycle }
        if lhsParts.train != rhsParts.train { return lhsParts.train < rhsParts.train }
        if lhsParts.build != rhsParts.build { return lhsParts.build < rhsParts.build }
        return lhsParts.suffix < rhsParts.suffix
    }

    /// Splits e.g. "24B2083" → (24, "B", 2083, "") and "24A5331b" → (24, "A", 5331, "b").
    private static func parse(_ build: String) -> (cycle: Int, train: String, build: Int, suffix: String) {
        let chars = Array(build)
        var idx = 0
        func take(_ predicate: (Character) -> Bool) -> String {
            let start = idx
            while idx < chars.count, predicate(chars[idx]) { idx += 1 }
            return String(chars[start..<idx])
        }
        let cycle = Int(take { $0.isNumber }) ?? 0
        let train = take { $0.isLetter }
        let build = Int(take { $0.isNumber }) ?? 0
        return (cycle, train, build, String(chars[idx...]))
    }
}

enum MacOSRelease {
    static func name(forMajorVersion major: Int) -> String {
        switch major {
        case 11: "Big Sur"
        case 12: "Monterey"
        case 13: "Ventura"
        case 14: "Sonoma"
        case 15: "Sequoia"
        case 26: "Tahoe"
        case 27: "Golden Gate"
        default: "macOS \(major)"
        }
    }
}
