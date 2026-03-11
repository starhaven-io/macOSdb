import ArgumentParser

@main
struct MacOSdb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macosdb",
        abstract: "Browse and compare open source components bundled in macOS releases.",
        version: "0.1.0",
        subcommands: [ListCommand.self, ShowCommand.self, CompareCommand.self, ScanCommand.self]
    )
}
