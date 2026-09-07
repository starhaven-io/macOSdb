import ArgumentParser
import Foundation

struct CompletionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Generate shell completions (bash, zsh, fish)."
    )

    @Argument(help: "Shell to generate completions for: bash, zsh, or fish.")
    var shell: String

    func run() throws {
        guard let completionShell = CompletionShell(rawValue: shell.lowercased()) else {
            throw ValidationError("Unsupported shell '\(shell)'. Must be one of: bash, zsh, fish.")
        }
        print(MacOSdb.completionScript(for: completionShell))
    }
}
