import ArgumentParser

@main
struct MacOSdb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macosdb",
        abstract: "Browse and compare open source components bundled in macOS and Xcode releases.",
        version: MacosdbVersion.current,
        subcommands: [
            CleanupCommand.self,
            CompareCommand.self,
            CompletionsCommand.self,
            ListCommand.self,
            ScanCommand.self,
            ShowCommand.self,
            ValidateCommand.self
        ]
    )
}
