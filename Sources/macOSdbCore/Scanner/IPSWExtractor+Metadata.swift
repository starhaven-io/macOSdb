import Foundation

extension IPSWExtractor {
    struct ManifestData {
        let osVersion: String
        let buildNumber: String
        let dmgRoles: [String: String]
        let kernelDeviceMap: [String: [String]]
    }

    func parseManifest(at path: URL) throws -> ManifestData {
        let data = try ScannerFileReader.data(
            at: path,
            confinedTo: path.deletingLastPathComponent(),
            maxBytes: Int(Self.maxMetadataSize)
        )
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else {
            throw ScannerError.metadataExtractionFailed(reason: "Invalid BuildManifest.plist format")
        }

        var osVersion = ""
        var buildNumber = ""
        var dmgRoles: [String: String] = [:]
        var kernelDeviceMap: [String: Set<String>] = [:]

        if let identities = plist["BuildIdentities"] as? [[String: Any]] {
            if let firstIdentity = identities.first {
                if let info = firstIdentity["Info"] as? [String: Any] {
                    buildNumber = info["BuildNumber"] as? String ?? ""
                }
                if let manifest = firstIdentity["Manifest"] as? [String: Any] {
                    if let osEntry = manifest["OS"] as? [String: Any],
                       let info = osEntry["Info"] as? [String: Any] {
                        osVersion = info["ProductVersion"] as? String ?? ""
                    }

                    for (roleName, roleValue) in manifest {
                        if let roleDict = roleValue as? [String: Any],
                           let info = roleDict["Info"] as? [String: Any],
                           let filePath = info["Path"] as? String,
                           filePath.hasSuffix(".dmg") || filePath.hasSuffix(".dmg.aea") {
                            let filename = URL(fileURLWithPath: filePath).lastPathComponent
                            dmgRoles[roleName] = filename
                        }
                    }
                }
            }

            for identity in identities {
                try Task.checkCancellation()
                guard let productType = identity["Ap,ProductType"] as? String,
                      let manifest = identity["Manifest"] as? [String: Any],
                      let kernelEntry = manifest["KernelCache"] as? [String: Any],
                      let kernelInfo = kernelEntry["Info"] as? [String: Any],
                      let kernelPath = kernelInfo["Path"] as? String else {
                    continue
                }
                let kernelFilename = URL(fileURLWithPath: kernelPath).lastPathComponent
                kernelDeviceMap[kernelFilename, default: []].insert(productType)
            }
        }

        if osVersion.isEmpty {
            osVersion = plist["ProductVersion"] as? String ?? ""
        }
        if buildNumber.isEmpty {
            buildNumber = plist["ProductBuildVersion"] as? String ?? ""
        }

        return ManifestData(
            osVersion: osVersion,
            buildNumber: buildNumber,
            dmgRoles: dmgRoles,
            kernelDeviceMap: kernelDeviceMap.mapValues { $0.sorted() }
        )
    }

    func parseRestorePlist(at path: URL) throws -> (osVersion: String, buildNumber: String) {
        let data = try ScannerFileReader.data(
            at: path,
            confinedTo: path.deletingLastPathComponent(),
            maxBytes: Int(Self.maxMetadataSize)
        )
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else {
            throw ScannerError.metadataExtractionFailed(reason: "Invalid Restore.plist format")
        }

        let osVersion = plist["ProductVersion"] as? String ?? ""
        let buildNumber = plist["ProductBuildVersion"] as? String ?? ""
        return (osVersion, buildNumber)
    }

    /// Parse OS version and build from an IPSW filename only when plist metadata is unavailable.
    func parseFromFilename(_ filename: String) -> (osVersion: String, buildNumber: String) {
        let regex = /UniversalMac_([0-9]+\.[0-9]+(?:\.[0-9]+)?)_([A-Za-z0-9]+)_Restore/
        guard let match = filename.firstMatch(of: regex) else {
            return ("", "")
        }
        return (String(match.1), String(match.2))
    }
}
