import ArgumentParser
import SwiftUI

import macOSdbKit

@main
struct MacOSdbEntryPoint {
    static func main() async throws {
        let executableName = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "macOSdb"
        guard ProcessInfo.processInfo.processName != executableName else {
            MacOSdbApp.main()
            return
        }

        // Invoked via symlink (e.g. macOSdb.app/Contents/MacOS/macosdb-tool) — run the CLI.
        await MacOSdbCLI.main()
    }
}

// Duplicates the command registration from Sources/macosdb/MacOSdb.swift so the
// Xcode app target does not need to compile the file that carries @main for SPM.
struct MacOSdbCLI: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "macosdb",
        abstract: "Browse and compare open source components bundled in macOS releases.",
        version: "1.2.1",
        subcommands: [ListCommand.self, ShowCommand.self, CompareCommand.self, ScanCommand.self]
    )
}
