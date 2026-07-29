import ArgumentParser
import Foundation
import macOSdbCore

struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare components between two releases."
    )

    @Argument(help: "First (older) version (e.g. 15.1), or a version-build slug (e.g. 15.1-24B2083).")
    var fromVersion: String

    @Argument(help: "Second (newer) version (e.g. 15.2), or a version-build slug.")
    var toVersion: String

    @Option(name: .long, help: "Product type: macOS or Xcode (default: macOS).")
    var product: String?

    @Flag(name: .long, help: "Only show components that changed.")
    var changed = false

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    @Option(name: .long, help: "Base URL or local data directory for release data (default: https://macosdb.com/api/v1/).")
    var dataURL: String?

    func run() async throws {
        let productType = try parseProductType(product)
        let provider = try makeDataProvider(dataURL: dataURL)

        async let fromRelease = resolveRelease(fromVersion, provider: provider, productType: productType)
        async let toRelease = resolveRelease(toVersion, provider: provider, productType: productType)

        guard let from = try await fromRelease else {
            printError("\(productType.displayName) \(fromVersion) not found.")
            throw ExitCode.failure
        }
        guard let toRel = try await toRelease else {
            printError("\(productType.displayName) \(toVersion) not found.")
            throw ExitCode.failure
        }

        let comparison = VersionComparer.compare(from: from, to: toRel)

        if json {
            try writeJSON(changed ? filteredComparison(comparison) : comparison)
            return
        }

        print("Comparing \(from.displayName) (\(from.buildNumber)) → \(toRel.displayName) (\(toRel.buildNumber))")
        print(comparison.summary)
        print("")

        printChanges(changed ? comparison.changedComponents : comparison.changes, from: from, to: toRel)

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

    private func printChanges(_ displayChanges: [ComponentChange], from: Release, to toRel: Release) {
        guard !displayChanges.isEmpty else { return }

        // Two builds of one version share an osVersion, so label those columns
        // by build instead (e.g. `compare 15.1-24B83 15.1-24B2083`).
        let sameVersion = from.osVersion == toRel.osVersion
        let fromLabel = sameVersion ? from.buildNumber : from.osVersion
        let toLabel = sameVersion ? toRel.buildNumber : toRel.osVersion

        print(
            "Component".padding(toLength: 24, withPad: " ", startingAt: 0)
                + fromLabel.padding(toLength: 20, withPad: " ", startingAt: 0)
                + toLabel.padding(toLength: 20, withPad: " ", startingAt: 0)
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

    private func filteredComparison(_ comparison: VersionComparison) -> VersionComparison {
        VersionComparison(
            from: comparison.from,
            to: comparison.to,
            changes: comparison.changedComponents,
            addedComponents: comparison.addedComponents,
            removedComponents: comparison.removedComponents
        )
    }
}
