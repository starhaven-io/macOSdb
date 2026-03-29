import ArgumentParser
import Foundation

@main
struct MacOSdb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macosdb",
        abstract: "Browse and compare open source components bundled in macOS releases.",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        subcommands: [ListCommand.self, ShowCommand.self, CompareCommand.self, ScanCommand.self, ValidateCommand.self]
    )
}
