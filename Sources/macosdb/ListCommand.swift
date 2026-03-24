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
            if lhsParts != rhsParts {
                return lhsParts.lexicographicallyPrecedes(rhsParts)
            }
            return lhs.buildNumber < rhs.buildNumber
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

        print(
            "Version".padding(toLength: 12, withPad: " ", startingAt: 0)
                + "Build".padding(toLength: 12, withPad: " ", startingAt: 0)
                + "Date".padding(toLength: 12, withPad: " ", startingAt: 0)
                + "Name"
        )
        print(String(repeating: "-", count: 56))

        for entry in entries {
            print(
                entry.osVersion.padding(toLength: 12, withPad: " ", startingAt: 0)
                    + entry.buildNumber.padding(toLength: 12, withPad: " ", startingAt: 0)
                    + (entry.releaseDate ?? "—").padding(toLength: 12, withPad: " ", startingAt: 0)
                    + entry.releaseName
            )
        }
    }
}
