import ArgumentParser
import Foundation
import macOSdbCore

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show components for a specific release."
    )

    @Argument(help: "Version to show (e.g. 15.6.1), or a version-build slug (e.g. 15.1-24B2083).")
    var version: String

    @Option(name: .long, help: "Exact build number to show (e.g. 24B2083) when a version has several.")
    var build: String?

    @Option(name: .long, help: "Product type: macOS or Xcode (default: macOS).")
    var product: String?

    @Option(name: .long, help: "Filter to a specific component name.")
    var component: String?

    @Flag(name: .long, help: "Include kernel and chip information.")
    var detailed = false

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    @Option(name: .long, help: "Base URL or local data directory for release data (default: https://macosdb.com/api/v1/).")
    var dataURL: String?

    func run() async throws {
        let productType = try parseProductType(product)
        let provider = try makeDataProvider(dataURL: dataURL)

        guard let release = try await resolveRelease(
            version, build: build, provider: provider, productType: productType
        ) else {
            let spec = build.map { "\(version) (\($0))" } ?? version
            printError("\(productType.displayName) \(spec) not found.")
            throw ExitCode.failure
        }

        if json {
            let output = component == nil ? release : release.withComponents(filteredComponents(release))
            try writeJSON(output)
            return
        }

        printReleaseMetadata(release)

        if detailed, !release.kernels.isEmpty {
            printKernelInfo(release)
        }

        printComponents(release)
    }

    private func printReleaseMetadata(_ release: Release) {
        printLine("\(release.displayName) (\(release.buildNumber))")
        if let date = release.releaseDate { printLine("Released: \(date)") }
        if release.isDeviceSpecific { printLine("Type: Device-specific build") }
        if let ipswURL = release.ipswURL { printLine("IPSW: \(ipswURL)") }
        if let xipURL = release.xipURL { printLine("XIP: \(xipURL)") }
        printLine("")

        if let sdks = release.sdks, !sdks.isEmpty {
            printLine("macOS SDKs:")
            for sdk in sdks {
                if let build = sdk.buildVersion {
                    printLine("  SDK \(sdk.sdkVersion) (\(build))")
                } else {
                    printLine("  SDK \(sdk.sdkVersion)")
                }
            }
            printLine("")
        }
    }

    private func printKernelInfo(_ release: Release) {
        printLine("Kernels:")
        for kernel in release.kernels {
            let xnu = kernel.xnuVersion.map { " / XNU \($0)" } ?? ""
            printLine("  \(kernel.chip) — Darwin \(kernel.darwinVersion)\(xnu)")
            printLine("    Devices: \(kernel.devices.joined(separator: ", "))")
        }
        printLine("")
        let chips = release.supportedChips.map(\.displayName).joined(separator: ", ")
        printLine("Supported chips: \(chips)")
        printLine("")
    }

    private func filteredComponents(_ release: Release) -> [Component] {
        guard let componentFilter = component else { return release.components }
        if let exact = release.component(named: componentFilter) {
            return [exact]
        }
        return release.components.filter { $0.name.lowercased().contains(componentFilter.lowercased()) }
    }

    private func printComponents(_ release: Release) {
        let components = filteredComponents(release)

        if components.isEmpty {
            printLine("No components found.")
            return
        }

        printLine(
            "Component".padding(toLength: 24, withPad: " ", startingAt: 0)
                + "Version".padding(toLength: 20, withPad: " ", startingAt: 0)
                + "Path"
        )
        printLine(String(repeating: "-", count: 80))

        for comp in components.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            printLine(
                comp.name.padding(toLength: 24, withPad: " ", startingAt: 0)
                    + comp.displayVersion.padding(toLength: 20, withPad: " ", startingAt: 0)
                    + comp.path
            )
        }
    }
}
