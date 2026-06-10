import Foundation
import OSLog

public actor DataProvider {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "DataProvider")

    private let baseURL: URL
    private let session: URLSession

    private var cachedIndexes: [ProductType: [ReleaseIndexEntry]] = [:]
    private var cachedReleases: [String: Release] = [:]

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public init() {
        // swiftlint:disable:next force_unwrapping
        self.baseURL = URL(string: "https://macosdb.com/api/v1/")!
        self.session = .shared
    }

    /// Fetches the release index for the given product type.
    public func fetchReleaseIndex(for productType: ProductType = .macOS) async throws -> [ReleaseIndexEntry] {
        if let cached = cachedIndexes[productType] {
            return cached
        }

        let indexPath = "\(productType.dataDirectory)/releases.json"

        let url = baseURL.appendingPathComponent(indexPath)
        Self.logger.debug("Fetching \(productType.displayName) release index from \(url)")

        let (data, response) = try await session.data(from: url)
        try validateResponse(response, url: url)

        let decoder = JSONDecoder()
        let index = try decoder.decode([ReleaseIndexEntry].self, from: data)
        cachedIndexes[productType] = index

        Self.logger.info("Loaded \(index.count) \(productType.displayName) releases from index")
        return index
    }

    public func fetchRelease(_ entry: ReleaseIndexEntry) async throws -> Release {
        // Build numbers aren't guaranteed unique across products, so namespace the
        // cache key by product directory.
        let cacheKey = "\(entry.resolvedProductType.dataDirectory)/\(entry.buildNumber)"
        if let cached = cachedReleases[cacheKey] {
            return cached
        }

        // dataFile comes from the index; reject path traversal so a crafted index
        // can't read outside the data directory when baseURL is a local file:// path.
        guard !entry.dataFile.contains("..") else {
            throw DataProviderError.invalidDataFile(entry.dataFile)
        }

        let relativePath = "\(entry.resolvedProductType.dataDirectory)/\(entry.dataFile)"
        let url = baseURL.appendingPathComponent(relativePath)
        Self.logger.debug("Fetching release data from \(url)")

        let (data, response) = try await session.data(from: url)
        try validateResponse(response, url: url)

        let decoder = JSONDecoder()
        let release = try decoder.decode(Release.self, from: data)
        cachedReleases[cacheKey] = release

        Self.logger.info("Loaded release: \(release.displayName) (\(release.buildNumber))")
        return release
    }

    public func fetchAllReleases(for productType: ProductType = .macOS) async throws -> [Release] {
        let index = try await fetchReleaseIndex(for: productType)

        let releases = await withTaskGroup(of: Release?.self, returning: [Release].self) { group in
            for entry in index {
                group.addTask {
                    do {
                        return try await self.fetchRelease(entry)
                    } catch {
                        Self.logger.error(
                            "Skipping \(entry.osVersion) (\(entry.buildNumber)): \(error.localizedDescription)"
                        )
                        return nil
                    }
                }
            }

            var releases: [Release] = []
            for await release in group {
                if let release {
                    releases.append(release)
                }
            }
            return releases.sorted()
        }

        // Surface an all-failed load as an error — an empty array reads as an empty catalog.
        guard index.isEmpty || !releases.isEmpty else {
            throw DataProviderError.allReleasesFailed(count: index.count)
        }
        return releases
    }

    public func findRelease(osVersion: String, productType: ProductType = .macOS) async throws -> Release? {
        let index = try await fetchReleaseIndex(for: productType)
        let matches = index.filter { $0.osVersion == osVersion }
        guard let entry = Self.preferredRelease(among: matches) else {
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
        entries.max { selectionRank($0) < selectionRank($1) }
    }

    /// Ranking key (higher is preferred). The first element orders GA > RC > beta and,
    /// within a maturity tier, universal > device-specific; the second breaks ties
    /// toward the later prerelease.
    private static func selectionRank(_ entry: ReleaseIndexEntry) -> (Int, Int) {
        let maturity = entry.isBeta ? 0 : (entry.isRC ? 1 : 2)
        let universal = entry.isDeviceSpecific ? 0 : 1
        return (maturity * 2 + universal, entry.betaNumber ?? entry.rcNumber ?? 0)
    }

    public func clearCache() {
        cachedIndexes.removeAll()
        cachedReleases.removeAll()
        URLCache.shared.removeAllCachedResponses()
    }

    private func validateResponse(_ response: URLResponse, url: URL) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            // Local file:// URLs don't return HTTPURLResponse
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw DataProviderError.httpError(statusCode: httpResponse.statusCode, url: url)
        }
    }
}

enum DataProviderError: LocalizedError {
    case httpError(statusCode: Int, url: URL)
    case allReleasesFailed(count: Int)
    case invalidDataFile(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let url):
            "HTTP \(statusCode) fetching \(url)"
        case .allReleasesFailed(let count):
            "Loaded the release index but failed to fetch any of its \(count) releases"
        case .invalidDataFile(let path):
            "Refusing to fetch release data with an unsafe path: \(path)"
        }
    }
}
