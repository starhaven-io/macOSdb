import Foundation

/// A release with its extracted open source component versions.
///
/// Supports macOS (IPSW firmware) and Xcode (.xip).
public struct Release: Codable, Identifiable, Hashable, Sendable {
    public var id: String { buildNumber }

    enum CodingKeys: String, CodingKey {
        case productType, osVersion, buildNumber, releaseName, releaseDate
        case ipswFile, ipswURL, xipFile, xipURL
        case isBeta, betaNumber, isRC, rcNumber, isDeviceSpecific
        case kernels, components, sdks, minimumOSVersion
    }

    public let productType: ProductType?
    public let osVersion: String
    public let buildNumber: String
    public let releaseName: String
    public let releaseDate: String?
    public let ipswFile: String?
    public let ipswURL: String?
    public let xipFile: String?
    public let xipURL: String?
    public let isBeta: Bool
    public let betaNumber: Int?
    public let isRC: Bool
    public let rcNumber: Int?
    public let isDeviceSpecific: Bool
    public let kernels: [KernelInfo]
    public let components: [Component]
    public let sdks: [SDKInfo]?
    public let minimumOSVersion: String?

    public init(
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

    public var majorVersion: Int {
        let parts = osVersion.split(separator: ".")
        return Int(parts.first ?? "") ?? 0
    }

    public var minorVersion: Int {
        let parts = osVersion.split(separator: ".")
        guard parts.count > 1 else { return 0 }
        return Int(parts[1]) ?? 0
    }

    public var patchVersion: Int {
        let parts = osVersion.split(separator: ".")
        guard parts.count > 2 else { return 0 }
        return Int(parts[2]) ?? 0
    }

    /// Derived from per-device chip resolution when available, falling back to kernel-level chip labels.
    public var supportedChips: [ChipFamily] {
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
    public var resolvedProductType: ProductType {
        productType ?? .macOS
    }

    public var displayName: String {
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

    public func component(named name: String) -> Component? {
        components.first { $0.name.lowercased() == name.lowercased() }
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public var betaLabel: String? {
        guard isBeta else { return nil }
        if let betaNumber {
            return "Developer Beta \(betaNumber)"
        }
        return "Beta"
    }

    /// Display label for release candidates, e.g. "RC" or "RC 2".
    public var rcLabel: String? {
        guard isRC else { return nil }
        if let rcNumber {
            return "RC \(rcNumber)"
        }
        return "RC"
    }

    /// True if this is any kind of pre-release (beta or RC).
    public var isPrerelease: Bool {
        isBeta || isRC
    }
}

/// An entry in the release index file (`releases.json`).
public struct ReleaseIndexEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { buildNumber }

    enum CodingKeys: String, CodingKey {
        case productType, osVersion, buildNumber, releaseName, releaseDate
        case isBeta, betaNumber, isRC, rcNumber, isDeviceSpecific
        case dataFile
    }

    public let productType: ProductType?
    public let osVersion: String
    public let buildNumber: String
    public let releaseName: String
    public let releaseDate: String?
    public let isBeta: Bool
    public let betaNumber: Int?
    public let isRC: Bool
    public let rcNumber: Int?
    public let isDeviceSpecific: Bool
    public let dataFile: String

    /// The resolved product type, defaulting to `.macOS` for backward compatibility with existing JSON.
    public var resolvedProductType: ProductType {
        productType ?? .macOS
    }

    public init(
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
}

extension Release: Comparable {
    public static func < (lhs: Release, rhs: Release) -> Bool {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion < rhs.majorVersion
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion < rhs.minorVersion
        }
        if lhs.patchVersion != rhs.patchVersion {
            return lhs.patchVersion < rhs.patchVersion
        }
        // Within same version: releases > RCs > betas
        if lhs.prereleaseRank != rhs.prereleaseRank {
            return lhs.prereleaseRank < rhs.prereleaseRank
        }
        return lhs.buildNumber < rhs.buildNumber
    }

    private var prereleaseRank: (Int, Int) {
        if isBeta { return (0, betaNumber ?? 0) }
        if isRC { return (1, rcNumber ?? 0) }
        return (2, 0)
    }
}

enum BuildNumber {
    /// Apple beta build numbers end with a lowercase letter (e.g. `25E5207k`),
    /// while release builds end with a digit (e.g. `24G90`).
    static func isBeta(_ buildNumber: String) -> Bool {
        guard let last = buildNumber.last else { return false }
        return last.isLetter && last.isLowercase
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
        default: "macOS \(major)"
        }
    }
}
