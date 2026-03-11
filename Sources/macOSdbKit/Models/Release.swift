import Foundation

/// A macOS release with its extracted open source component versions.
public struct Release: Codable, Identifiable, Hashable, Sendable {
    public var id: String { buildNumber }

    public let osVersion: String
    public let buildNumber: String
    public let releaseName: String
    public let releaseDate: String?
    public let ipswFile: String?
    /// Bump when scanner logic changes in a way that would produce different output.
    public let scannerVersion: String?
    public let isBeta: Bool
    public let betaNumber: Int?
    public let isRC: Bool
    public let rcNumber: Int?
    public let kernels: [KernelInfo]
    public let components: [Component]

    public init(
        osVersion: String,
        buildNumber: String,
        releaseName: String,
        releaseDate: String? = nil,
        ipswFile: String? = nil,
        scannerVersion: String? = nil,
        isBeta: Bool = false,
        betaNumber: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil,
        kernels: [KernelInfo] = [],
        components: [Component] = []
    ) {
        self.osVersion = osVersion
        self.buildNumber = buildNumber
        self.releaseName = releaseName
        self.releaseDate = releaseDate
        self.ipswFile = ipswFile
        self.scannerVersion = scannerVersion
        self.isBeta = isBeta
        self.betaNumber = betaNumber
        self.isRC = isRC
        self.rcNumber = rcNumber
        self.kernels = kernels
        self.components = components
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

    public var supportedDevices: [String] {
        kernels.flatMap(\.devices)
            .reduce(into: [String]()) { result, device in
                if !result.contains(device) {
                    result.append(device)
                }
            }
    }

    public var displayName: String {
        "macOS \(osVersion) \(releaseName)"
    }

    public func component(named name: String) -> Component? {
        components.first { $0.name.lowercased() == name.lowercased() }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        releaseName = try container.decode(String.self, forKey: .releaseName)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        ipswFile = try container.decodeIfPresent(String.self, forKey: .ipswFile)
        scannerVersion = try container.decodeIfPresent(String.self, forKey: .scannerVersion)
        isBeta = try container.decodeIfPresent(Bool.self, forKey: .isBeta) ?? false
        betaNumber = try container.decodeIfPresent(Int.self, forKey: .betaNumber)
        isRC = try container.decodeIfPresent(Bool.self, forKey: .isRC) ?? false
        rcNumber = try container.decodeIfPresent(Int.self, forKey: .rcNumber)
        kernels = try container.decodeIfPresent([KernelInfo].self, forKey: .kernels) ?? []
        components = try container.decodeIfPresent([Component].self, forKey: .components) ?? []
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

    public let osVersion: String
    public let buildNumber: String
    public let releaseName: String
    public let releaseDate: String?
    public let isBeta: Bool
    public let betaNumber: Int?
    public let isRC: Bool
    public let rcNumber: Int?
    public let dataFile: String

    public init(
        osVersion: String,
        buildNumber: String,
        releaseName: String,
        releaseDate: String? = nil,
        isBeta: Bool = false,
        betaNumber: Int? = nil,
        isRC: Bool = false,
        rcNumber: Int? = nil,
        dataFile: String
    ) {
        self.osVersion = osVersion
        self.buildNumber = buildNumber
        self.releaseName = releaseName
        self.releaseDate = releaseDate
        self.isBeta = isBeta
        self.betaNumber = betaNumber
        self.isRC = isRC
        self.rcNumber = rcNumber
        self.dataFile = dataFile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        releaseName = try container.decode(String.self, forKey: .releaseName)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        isBeta = try container.decodeIfPresent(Bool.self, forKey: .isBeta) ?? false
        betaNumber = try container.decodeIfPresent(Int.self, forKey: .betaNumber)
        isRC = try container.decodeIfPresent(Bool.self, forKey: .isRC) ?? false
        rcNumber = try container.decodeIfPresent(Int.self, forKey: .rcNumber)
        dataFile = try container.decode(String.self, forKey: .dataFile)
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
        return lhs.prereleaseRank < rhs.prereleaseRank
    }

    private var prereleaseRank: Int {
        if isBeta { return 0 }
        if isRC { return 1 }
        return 2
    }
}

public enum BuildNumber {
    /// Apple beta build numbers end with a lowercase letter (e.g. `25E5207k`),
    /// while release builds end with a digit (e.g. `24G90`).
    public static func isBeta(_ buildNumber: String) -> Bool {
        guard let last = buildNumber.last else { return false }
        return last.isLetter && last.isLowercase
    }
}

public enum MacOSRelease {
    public static func name(forMajorVersion major: Int) -> String {
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
