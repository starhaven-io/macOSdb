import ArgumentParser
import Foundation
import macOSdbKit

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List known macOS releases."
    )

    @Option(name: .long, help: "Filter by major macOS version (e.g. 15).")
    var major: Int?

    @Option(name: .long, help: "Base URL for release data (default: GitHub).")
    var dataURL: String?

    func run() async throws {
        let provider = makeDataProvider(dataURL: dataURL)
        let index = try await provider.fetchReleaseIndex()

        var entries = index.sorted { lhs, rhs in
            let lhsParts = lhs.osVersion.split(separator: ".").compactMap { Int($0) }
            let rhsParts = rhs.osVersion.split(separator: ".").compactMap { Int($0) }
            return lhsParts.lexicographicallyPrecedes(rhsParts)
        }

        if let major {
            entries = entries.filter { entry in
                let parts = entry.osVersion.split(separator: ".")
                return Int(parts.first ?? "") == major
            }
        }

        if entries.isEmpty {
            print("No releases found.")
            return
        }

        print(String(format: "%-12s %-12s %-12s %s", "Version", "Build", "Date", "Name"))
        print(String(repeating: "-", count: 56))

        for entry in entries {
            print(String(
                format: "%-12s %-12s %-12s %s",
                entry.osVersion,
                entry.buildNumber,
                entry.releaseDate ?? "—",
                entry.releaseName
            ))
        }
    }
}
