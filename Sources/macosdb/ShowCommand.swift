import ArgumentParser
import Foundation
import macOSdbKit

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show components for a specific macOS release."
    )

    @Argument(help: "macOS version to show (e.g. 15.6.1).")
    var version: String

    @Option(name: .long, help: "Filter to a specific component name.")
    var component: String?

    @Flag(name: .long, help: "Include kernel and chip information.")
    var detailed = false

    @Option(name: .long, help: "Base URL for release data (default: GitHub).")
    var dataURL: String?

    func run() async throws {
        let provider = makeDataProvider(dataURL: dataURL)

        guard let release = try await provider.findRelease(osVersion: version) else {
            print("Release macOS \(version) not found.")
            throw ExitCode.failure
        }

        print("macOS \(release.osVersion) \(release.releaseName) (\(release.buildNumber))")
        if let date = release.releaseDate {
            print("Released: \(date)")
        }
        print("")

        if detailed, !release.kernels.isEmpty {
            print("Kernels:")
            for kernel in release.kernels {
                let xnu = kernel.xnuVersion.map { " / XNU \($0)" } ?? ""
                print("  \(kernel.chip) — Darwin \(kernel.darwinVersion)\(xnu)")
                print("    Devices: \(kernel.devices.joined(separator: ", "))")
            }
            print("")

            let chips = release.supportedChips.map(\.displayName).joined(separator: ", ")
            print("Supported chips: \(chips)")
            print("")
        }

        var components = release.components
        if let componentFilter = component {
            components = components.filter { $0.name.lowercased().contains(componentFilter.lowercased()) }
        }

        if components.isEmpty {
            print("No components found.")
            return
        }

        print(String(format: "%-24s %-20s %s", "Component", "Version", "Path"))
        print(String(repeating: "-", count: 80))

        for comp in components.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            print(String(
                format: "%-24s %-20s %s",
                comp.name,
                comp.displayVersion,
                comp.path
            ))
        }
    }
}
