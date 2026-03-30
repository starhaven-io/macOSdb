import ArgumentParser
import Foundation
import macOSdbKit

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show components for a specific release."
    )

    @Argument(help: "Version to show (e.g. 15.6.1).")
    var version: String

    @Option(name: .long, help: "Product type: macOS or Xcode (default: macOS).")
    var product: String?

    @Option(name: .long, help: "Filter to a specific component name.")
    var component: String?

    @Flag(name: .long, help: "Include kernel and chip information.")
    var detailed = false

    @Option(name: .long, help: "Base URL for release data (default: GitHub).")
    var dataURL: String?

    func run() async throws {
        let productType = parseProductType(product)
        let provider = makeDataProvider(dataURL: dataURL)

        guard let release = try await provider.findRelease(osVersion: version, productType: productType) else {
            print("\(productType.displayName) \(version) not found.")
            throw ExitCode.failure
        }

        printReleaseMetadata(release)

        if detailed, !release.kernels.isEmpty {
            printKernelInfo(release)
        }

        printComponents(release)
    }

    private func printReleaseMetadata(_ release: Release) {
        print("\(release.displayName) (\(release.buildNumber))")
        if let date = release.releaseDate { print("Released: \(date)") }
        if release.isDeviceSpecific { print("Type: Device-specific build") }
        if let ipswURL = release.ipswURL { print("IPSW: \(ipswURL)") }
        if let xipURL = release.xipURL { print("XIP: \(xipURL)") }
        print("")

        if let sdks = release.sdks, !sdks.isEmpty {
            print("macOS SDKs:")
            for sdk in sdks {
                print("  SDK \(sdk.sdkVersion)")
            }
            print("")
        }
    }

    private func printKernelInfo(_ release: Release) {
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

    private func printComponents(_ release: Release) {
        var components = release.components
        if let componentFilter = component {
            components = components.filter { $0.name.lowercased().contains(componentFilter.lowercased()) }
        }

        if components.isEmpty {
            print("No components found.")
            return
        }

        print(
            "Component".padding(toLength: 24, withPad: " ", startingAt: 0)
                + "Version".padding(toLength: 20, withPad: " ", startingAt: 0)
                + "Path"
        )
        print(String(repeating: "-", count: 80))

        for comp in components.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            print(
                comp.name.padding(toLength: 24, withPad: " ", startingAt: 0)
                    + comp.displayVersion.padding(toLength: 20, withPad: " ", startingAt: 0)
                    + comp.path
            )
        }
    }
}
