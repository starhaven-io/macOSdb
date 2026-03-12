import ArgumentParser

@main
struct MacOSdb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macosdb",
        abstract: "Browse and compare open source components bundled in macOS releases.",
        version: "1.2.1",
        subcommands: [ListCommand.self, ShowCommand.self, CompareCommand.self, ScanCommand.self]
    )
}
