import Foundation
import OSLog

public actor DataProvider {
    private static let logger = Logger(subsystem: "io.linnane.macosdb", category: "DataProvider")

    private let baseURL: URL
    private let session: URLSession

    private var cachedIndex: [ReleaseIndexEntry]?
    private var cachedReleases: [String: Release] = [:]

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public init(owner: String = "p-linnane", repo: String = "macOSdb", branch: String = "main") {
        // swiftlint:disable:next force_unwrapping
        self.baseURL = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/data/")!
        self.session = .shared
    }

    public func fetchReleaseIndex() async throws -> [ReleaseIndexEntry] {
        if let cached = cachedIndex {
            return cached
        }

        let url = baseURL.appendingPathComponent("releases.json")
        Self.logger.debug("Fetching release index from \(url)")

        let (data, response) = try await session.data(from: url)
        try validateResponse(response, url: url)

        let decoder = JSONDecoder()
        let index = try decoder.decode([ReleaseIndexEntry].self, from: data)
        cachedIndex = index

        Self.logger.info("Loaded \(index.count) releases from index")
        return index
    }

    public func fetchRelease(_ entry: ReleaseIndexEntry) async throws -> Release {
        if let cached = cachedReleases[entry.buildNumber] {
            return cached
        }

        let url = baseURL.appendingPathComponent(entry.dataFile)
        Self.logger.debug("Fetching release data from \(url)")

        let (data, response) = try await session.data(from: url)
        try validateResponse(response, url: url)

        let decoder = JSONDecoder()
        let release = try decoder.decode(Release.self, from: data)
        cachedReleases[entry.buildNumber] = release

        Self.logger.info("Loaded release: macOS \(release.osVersion) (\(release.buildNumber))")
        return release
    }

    public func fetchAllReleases() async throws -> [Release] {
        let index = try await fetchReleaseIndex()

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

    public func findRelease(osVersion: String) async throws -> Release? {
        let index = try await fetchReleaseIndex()
        guard let entry = index.first(where: { $0.osVersion == osVersion }) else {
            return nil
        }
        return try await fetchRelease(entry)
    }

    public func clearCache() {
        cachedIndex = nil
        cachedReleases.removeAll()
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
