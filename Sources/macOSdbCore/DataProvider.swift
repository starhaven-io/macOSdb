import Foundation
import OSLog

package actor DataProvider {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "DataProvider")
    private static let maxIndexBytes = 4 * 1_024 * 1_024
    private static let maxReleaseBytes = 16 * 1_024 * 1_024

    private let baseURL: URL
    private let session: URLSession

    private var cachedIndexes: [ProductType: [ReleaseIndexEntry]] = [:]
    private var cachedReleases: [String: Release] = [:]

    package init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? Self.makeSession()
    }

    package init() {
        // swiftlint:disable:next force_unwrapping
        self.baseURL = URL(string: "https://macosdb.com/api/v1/")!
        self.session = Self.makeSession()
    }

    /// Fetches the release index for the given product type.
    package func fetchReleaseIndex(for productType: ProductType = .macOS) async throws -> [ReleaseIndexEntry] {
        if let cached = cachedIndexes[productType] {
            return cached
        }

        let indexPath = "\(productType.dataDirectory)/releases.json"

        let url = baseURL.appendingPathComponent(indexPath)
        Self.logger.debug("Fetching \(productType.displayName) release index from \(url)")

        let data = try await loadData(
            from: url,
            limit: Self.maxIndexBytes,
            localRoot: try localProductRoot(for: productType)
        )

        let decoder = JSONDecoder()
        let index = try decoder.decode([ReleaseIndexEntry].self, from: data)
        try Self.validateIndex(index, for: productType)
        cachedIndexes[productType] = index

        Self.logger.info("Loaded \(index.count) \(productType.displayName) releases from index")
        return index
    }

    package func fetchRelease(_ entry: ReleaseIndexEntry) async throws -> Release {
        let productType = entry.resolvedProductType
        guard let expectedDataFile = productType.canonicalDataFile(
            osVersion: entry.osVersion,
            buildNumber: entry.buildNumber
        ), entry.dataFile == expectedDataFile else {
            throw DataProviderError.invalidDataFile(entry.dataFile)
        }

        // Validate the caller-supplied pointer before consulting the identity
        // cache. Otherwise a forged entry can inherit a previously cached
        // release without satisfying the canonical-pointer contract.
        let cacheKey = "\(productType.dataDirectory)/\(entry.osVersion)/\(entry.buildNumber)"
        if let cached = cachedReleases[cacheKey] {
            return cached
        }

        let relativePath = "\(productType.dataDirectory)/\(entry.dataFile)"
        let url = baseURL.appendingPathComponent(relativePath)
        Self.logger.debug("Fetching release data from \(url)")

        let data = try await loadData(
            from: url,
            limit: Self.maxReleaseBytes,
            localRoot: try localProductRoot(for: productType)
        )

        let decoder = JSONDecoder()
        let release = try decoder.decode(Release.self, from: data)
        guard release.osVersion == entry.osVersion,
              release.buildNumber == entry.buildNumber,
              release.resolvedProductType == productType else {
            throw DataProviderError.releaseIdentityMismatch(
                expected: "\(entry.osVersion)-\(entry.buildNumber)",
                actual: "\(release.osVersion)-\(release.buildNumber)"
            )
        }
        cachedReleases[cacheKey] = release

        Self.logger.info("Loaded release: \(release.displayName) (\(release.buildNumber))")
        return release
    }

    package func findRelease(osVersion: String, productType: ProductType = .macOS) async throws -> Release? {
        let index = try await fetchReleaseIndex(for: productType)
        let matches = index.filter { $0.osVersion == osVersion }
        guard let entry = Self.preferredRelease(among: matches) else {
            return nil
        }
        return try await fetchRelease(entry)
    }

    /// Fetches one exact build when a version has multiple entries.
    package func findRelease(
        osVersion: String,
        buildNumber: String,
        productType: ProductType = .macOS
    ) async throws -> Release? {
        let index = try await fetchReleaseIndex(for: productType)
        guard let entry = index.first(where: {
            $0.osVersion == osVersion && $0.buildNumber == buildNumber
        }) else {
            return nil
        }
        return try await fetchRelease(entry)
    }

    /// Selects the most representative build among index entries that share an
    /// `osVersion`, preferring a final release over RCs/betas and a universal build
    /// over device-specific re-releases. Returns `nil` for empty input.
    ///
    /// Several versions list more than one build — e.g. macOS 15.1 carries the
    /// device-specific 24B2083 ahead of the GA 24B83 — so a naive first match would
    /// resolve `show`/`compare` to the wrong build.
    static func preferredRelease(among entries: [ReleaseIndexEntry]) -> ReleaseIndexEntry? {
        entries.max { lhs, rhs in
            let lhsRank = selectionRank(lhs)
            let rhsRank = selectionRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return BuildNumber.less(lhs.buildNumber, rhs.buildNumber)
        }
    }

    /// Ranking key (higher is preferred). The first element orders GA > RC > beta and,
    /// within a maturity tier, universal > device-specific; the remaining elements
    /// break ties toward the later prerelease and replacement revision.
    private static func selectionRank(_ entry: ReleaseIndexEntry) -> (Int, Int, Int) {
        let maturity = entry.isBeta ? 0 : (entry.isRC ? 1 : 2)
        let universal = entry.isDeviceSpecific ? 0 : 1
        let revision = entry.isBeta ? entry.betaRevision ?? 1 : 0
        return (maturity * 2 + universal, entry.betaNumber ?? entry.rcNumber ?? 0, revision)
    }

    private func validateResponse(_ response: URLResponse, url: URL) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            // Local file:// URLs don't return HTTPURLResponse
            return
        }

        guard httpResponse.url?.scheme?.lowercased() == "https" else {
            throw DataProviderError.insecureBaseURL(httpResponse.url ?? url)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw DataProviderError.httpError(statusCode: httpResponse.statusCode, url: url)
        }
    }

    private func loadData(from url: URL, limit: Int, localRoot: URL?) async throws -> Data {
        if let localRoot {
            do {
                return try ScannerFileReader.data(at: url, confinedTo: localRoot, maxBytes: limit)
            } catch {
                throw DataProviderError.invalidDataFile(url.path)
            }
        }
        guard url.scheme?.lowercased() == "https" else {
            throw DataProviderError.insecureBaseURL(url)
        }

        let (bytes, response) = try await session.bytes(from: url)
        try validateResponse(response, url: url)
        if response.expectedContentLength > Int64(limit) {
            try Self.validateResponseSize(Int(response.expectedContentLength), limit: limit, url: url)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), limit))
        }
        for try await byte in bytes {
            try Self.validateResponseSize(data.count + 1, limit: limit, url: url)
            data.append(byte)
        }
        return data
    }

    private func localProductRoot(for productType: ProductType) throws -> URL? {
        guard baseURL.isFileURL else { return nil }
        let resolvedBase = baseURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedProduct = baseURL.appendingPathComponent(productType.dataDirectory)
            .resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
        guard resolvedProduct.path.hasPrefix(prefix) else {
            throw DataProviderError.invalidDataFile(resolvedProduct.path)
        }
        return resolvedProduct
    }

    private static func validateIndex(_ index: [ReleaseIndexEntry], for productType: ProductType) throws {
        var identities = Set<String>()
        var dataFiles = Set<String>()
        for entry in index {
            guard entry.resolvedProductType == productType,
                  let expected = productType.canonicalDataFile(
                      osVersion: entry.osVersion,
                      buildNumber: entry.buildNumber
                  ), entry.dataFile == expected,
                  identities.insert("\(entry.osVersion)\u{0}\(entry.buildNumber)").inserted,
                  dataFiles.insert(entry.dataFile).inserted else {
                throw DataProviderError.invalidDataFile(entry.dataFile)
            }
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    static func validateResponseSize(_ size: Int, limit: Int, url: URL) throws {
        guard size <= limit else {
            throw DataProviderError.responseTooLarge(url: url, limit: limit)
        }
    }
}

enum DataProviderError: LocalizedError {
    case httpError(statusCode: Int, url: URL)
    case invalidDataFile(String)
    case releaseIdentityMismatch(expected: String, actual: String)
    case responseTooLarge(url: URL, limit: Int)
    case insecureBaseURL(URL)

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let url):
            "HTTP \(statusCode) fetching \(url)"
        case .invalidDataFile(let path):
            "Refusing release data with an invalid or unsafe path from the index: \(path)"
        case .releaseIdentityMismatch(let expected, let actual):
            "Release detail identity \(actual) does not match index entry \(expected)"
        case .responseTooLarge(let url, let limit):
            "Response from \(url) exceeds the \(limit)-byte limit"
        case .insecureBaseURL(let url):
            "Refusing non-HTTPS data source: \(url)"
        }
    }
}
