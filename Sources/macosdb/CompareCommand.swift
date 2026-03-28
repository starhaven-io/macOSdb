import ArgumentParser
import Foundation
import macOSdbKit

struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare components between two releases."
    )

    @Argument(help: "First (older) version (e.g. 15.1).")
    var fromVersion: String

    @Argument(help: "Second (newer) version (e.g. 15.2).")
    var toVersion: String

    @Option(name: .long, help: "Product type: macOS or Xcode (default: macOS).")
    var product: String?

    @Flag(name: .long, help: "Only show components that changed.")
    var changed = false

    @Option(name: .long, help: "Base URL for release data (default: GitHub).")
    var dataURL: String?

    func run() async throws {
        let productType = parseProductType(product)
        let provider = makeDataProvider(dataURL: dataURL)

        async let fromRelease = provider.findRelease(osVersion: fromVersion, productType: productType)
        async let toRelease = provider.findRelease(osVersion: toVersion, productType: productType)

        guard let from = try await fromRelease else {
            print("\(productType.displayName) \(fromVersion) not found.")
            throw ExitCode.failure
        }
        guard let toRel = try await toRelease else {
            print("\(productType.displayName) \(toVersion) not found.")
            throw ExitCode.failure
        }

        let comparison = VersionComparer.compare(from: from, to: toRel)

        print("Comparing \(from.displayName) → \(toRel.displayName)")
        print(comparison.summary)
        print("")

        let displayChanges = changed ? comparison.changedComponents : comparison.changes
        if !displayChanges.isEmpty {
            print(
                "Component".padding(toLength: 24, withPad: " ", startingAt: 0)
                    + from.osVersion.padding(toLength: 20, withPad: " ", startingAt: 0)
                    + toRel.osVersion.padding(toLength: 20, withPad: " ", startingAt: 0)
                    + "Status"
            )
            print(String(repeating: "-", count: 80))

            for change in displayChanges {
                let symbol: String
                switch change.direction {
                case .upgraded: symbol = "↑"
                case .downgraded: symbol = "↓"
                case .unchanged: symbol = "="
                }

                print(
                    change.name.padding(toLength: 24, withPad: " ", startingAt: 0)
                        + change.fromVersion.padding(toLength: 20, withPad: " ", startingAt: 0)
                        + change.toVersion.padding(toLength: 20, withPad: " ", startingAt: 0)
                        + symbol
                )
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
