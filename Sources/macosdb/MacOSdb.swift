import ArgumentParser
import Foundation

@main
struct MacOSdb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macosdb",
        abstract: "Browse and compare open source components bundled in macOS and Xcode releases.",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        subcommands: [CleanupCommand.self, CompareCommand.self, ListCommand.self, ScanCommand.self, ShowCommand.self, ValidateCommand.self]
    )
}
