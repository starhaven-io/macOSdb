import ArgumentParser
import Foundation
import macOSdbKit

struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare components between two macOS releases."
    )

    @Argument(help: "First (older) macOS version (e.g. 15.1).")
    var fromVersion: String

    @Argument(help: "Second (newer) macOS version (e.g. 15.2).")
    var toVersion: String

    @Flag(name: .long, help: "Only show components that changed.")
    var changed = false

    @Option(name: .long, help: "Base URL for release data (default: GitHub).")
    var dataURL: String?

    func run() async throws {
        let provider = makeDataProvider(dataURL: dataURL)

        async let fromRelease = provider.findRelease(osVersion: fromVersion)
        async let toRelease = provider.findRelease(osVersion: toVersion)

        guard let from = try await fromRelease else {
            print("Release macOS \(fromVersion) not found.")
            throw ExitCode.failure
        }
        guard let toRel = try await toRelease else {
            print("Release macOS \(toVersion) not found.")
            throw ExitCode.failure
        }

        let comparison = VersionComparer.compare(from: from, to: toRel)

        print("Comparing macOS \(from.osVersion) → \(toRel.osVersion)")
        print(comparison.summary)
        print("")

        let displayChanges = changed ? comparison.changedComponents : comparison.changes
        if !displayChanges.isEmpty {
            print(String(format: "%-24s %-20s %-20s %s", "Component", from.osVersion, toRel.osVersion, "Status"))
            print(String(repeating: "-", count: 80))

            for change in displayChanges {
                let symbol: String
                switch change.direction {
                case .upgraded: symbol = "↑"
                case .downgraded: symbol = "↓"
                case .unchanged: symbol = "="
                }

                print(String(
                    format: "%-24s %-20s %-20s %s",
                    change.name,
                    change.fromVersion,
                    change.toVersion,
                    symbol
                ))
            }
        }

        if !comparison.addedComponents.isEmpty {
            print("")
            print("Added:")
            for comp in comparison.addedComponents {
                print("  + \(comp.name) \(comp.displayVersion)")
            }
        }

        if !comparison.removedComponents.isEmpty {
            print("")
            print("Removed:")
            for comp in comparison.removedComponents {
                print("  - \(comp.name) \(comp.displayVersion)")
            }
        }
    }
}
