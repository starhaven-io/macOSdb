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
        if let cached = cachedReleases[entry.buildNumber] {
            return cached
        }

        let relativePath = "\(entry.resolvedProductType.dataDirectory)/\(entry.dataFile)"
        let url = baseURL.appendingPathComponent(relativePath)
        Self.logger.debug("Fetching release data from \(url)")

        let (data, response) = try await session.data(from: url)
        try validateResponse(response, url: url)

        let decoder = JSONDecoder()
        let release = try decoder.decode(Release.self, from: data)
        cachedReleases[entry.buildNumber] = release

        Self.logger.info("Loaded release: macOS \(release.osVersion) (\(release.buildNumber))")
        return release
    }

    public func fetchAllReleases(for productType: ProductType = .macOS) async throws -> [Release] {
        let index = try await fetchReleaseIndex(for: productType)

        return await withTaskGroup(of: Release?.self, returning: [Release].self) { group in
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
    }

    public func findRelease(osVersion: String, productType: ProductType = .macOS) async throws -> Release? {
        let index = try await fetchReleaseIndex(for: productType)
        guard let entry = index.first(where: { $0.osVersion == osVersion }) else {
            return nil
        }
        return try await fetchRelease(entry)
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

public enum DataProviderError: LocalizedError {
    case httpError(statusCode: Int, url: URL)

    public var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let url):
            "HTTP \(statusCode) fetching \(url)"
        }
    }
}
