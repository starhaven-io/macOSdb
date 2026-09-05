import Foundation

package enum ReleasePublicationValidator {
    package static func validate(_ release: Release) throws {
        guard release.resolvedProductType.canonicalDataFile(
            osVersion: release.osVersion,
            buildNumber: release.buildNumber
        ) != nil else {
            throw ReleasePublicationError.invalid("version or build identifier is not canonical")
        }
        guard !release.releaseName.isEmpty,
              let releaseDate = release.releaseDate,
              isValidDate(releaseDate) else {
            throw ReleasePublicationError.invalid("release name or date is missing or invalid")
        }
        try validatePrereleaseMetadata(release)
        try validateComponents(release)

        switch release.resolvedProductType {
        case .macOS:
            try validateMacOS(release)
        case .xcode:
            try validateXcode(release)
        }
    }

    private static func validatePrereleaseMetadata(_ release: Release) throws {
        guard !(release.isBeta && release.isRC),
              release.betaNumber.map({ $0 > 0 }) ?? true,
              release.betaRevision.map({ $0 >= 2 }) ?? true,
              release.rcNumber.map({ $0 > 0 }) ?? true,
              release.isBeta || (release.betaNumber == nil && release.betaRevision == nil),
              release.isRC || release.rcNumber == nil,
              release.betaRevision == nil || release.betaNumber != nil else {
            throw ReleasePublicationError.invalid("prerelease metadata is inconsistent")
        }
    }

    private static func validateComponents(_ release: Release) throws {
        let expected = expectedComponentSources(for: release.resolvedProductType)
        var actual: [String: ComponentSource] = [:]
        for component in release.components {
            guard actual[component.name] == nil,
                  let version = component.version,
                  !version.isEmpty,
                  component.path.hasPrefix("/") else {
                throw ReleasePublicationError.invalid("components are duplicate or incomplete")
            }
            actual[component.name] = component.source
        }
        guard actual == expected else {
            throw ReleasePublicationError.invalid("tracked component set is incomplete or unconfigured")
        }
    }

    private static func expectedComponentSources(for productType: ProductType) -> [String: ComponentSource] {
        var result: [String: ComponentSource] = [:]
        let definitions: [ComponentDefinition]
        switch productType {
        case .macOS:
            definitions = filesystemComponents + dyldCacheComponents
        case .xcode:
            definitions = toolchainComponents + developerComponents + frameworkComponents
        }
        for definition in definitions {
            result[definition.name] = definition.source
        }
        if productType == .xcode {
            // Python is discovered dynamically from Python3.framework rather
            // than declared in ScannerConfig, but it is part of the published
            // Xcode component contract.
            result["Python"] = .filesystem
            for definition in sdkComponents {
                result[definition.name] = .sdk
            }
        }
        return result
    }

    private static func validateMacOS(_ release: Release) throws {
        let expectedFile = "UniversalMac_\(release.osVersion)_\(release.buildNumber)_Restore.ipsw"
        let expectedName = Int(release.osVersion.split(separator: ".").first ?? "")
            .map(MacOSRelease.name(forMajorVersion:))
        guard let ipswFile = release.ipswFile,
              let ipswURL = release.ipswURL,
              ipswFile == expectedFile,
              release.releaseName == expectedName,
              isAllowedAppleURL(ipswURL, exactHost: "updates.cdn-apple.com"),
              URL(string: ipswURL)?.lastPathComponent == ipswFile,
              !release.kernels.isEmpty else {
            throw ReleasePublicationError.invalid("IPSW source or kernels are incomplete")
        }

        let earlyVirtualMacBuilds = ["21A5268h", "21A5284e", "21A5294g"]
        for kernel in release.kernels {
            let permitsNoDevices = kernel.chip == "A12Z (DTK)"
                || (kernel.chip == "Virtual Mac" && earlyVirtualMacBuilds.contains(release.buildNumber))
            guard !kernel.file.isEmpty,
                  !kernel.darwinVersion.isEmpty,
                  !(kernel.xnuVersion?.isEmpty ?? true),
                  !kernel.arch.isEmpty,
                  !kernel.chip.isEmpty,
                  permitsNoDevices || !kernel.devices.isEmpty else {
                throw ReleasePublicationError.invalid("kernel metadata is incomplete")
            }
        }
    }

    private static func validateXcode(_ release: Release) throws {
        guard let xipFile = release.xipFile,
              let xipURL = release.xipURL,
              xcodeVersion(from: xipFile) == release.osVersion,
              release.releaseName == "Xcode \(release.osVersion)",
              isAllowedAppleURL(xipURL, exactHost: "developer.apple.com"),
              XcodeScanner.xipFilename(fromURLString: xipURL) == xipFile,
              let minimumOSVersion = release.minimumOSVersion,
              !minimumOSVersion.isEmpty,
              let sdks = release.sdks,
              !sdks.isEmpty else {
            throw ReleasePublicationError.invalid("Xcode source, minimum OS, or SDK metadata is incomplete")
        }

        var versions = Set<String>()
        for sdk in sdks {
            guard !sdk.sdkVersion.isEmpty,
                  let buildVersion = sdk.buildVersion,
                  !buildVersion.isEmpty,
                  versions.insert(sdk.sdkVersion).inserted else {
                throw ReleasePublicationError.invalid("SDK metadata is incomplete or duplicated")
            }
        }
    }

    private static func xcodeVersion(from filename: String) -> String? {
        let pattern = /^Xcode_([0-9]+(?:\.[0-9]+)*)(?:_[A-Za-z0-9._~%+-]+)?\.xip$/
        guard let match = filename.wholeMatch(of: pattern) else { return nil }
        let version = String(match.1)
        return version.contains(".") ? version : "\(version).0"
    }

    private static func isAllowedAppleURL(_ value: String, exactHost: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        return host == exactHost
    }

    private static func isValidDate(_ value: String) -> Bool {
        guard value.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = components.date else { return false }
        let resolved = components.calendar?.dateComponents([.year, .month, .day], from: date)
        return resolved?.year == parts[0] && resolved?.month == parts[1] && resolved?.day == parts[2]
    }
}

package enum ReleasePublicationError: LocalizedError {
    case invalid(String)

    package var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            "Release is not safe to publish: \(reason)"
        }
    }
}
