import ArgumentParser
import Foundation
import macOSdbCore

struct IdentityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity",
        abstract: "Check that an IPSW's own metadata records the expected version and build."
    )

    @Argument(help: "IPSW file to check.")
    var ipswPath: String

    @Option(name: .long, help: "Version the IPSW metadata must record.")
    var expectedVersion: String

    @Option(name: .long, help: "Build the IPSW metadata must record.")
    var expectedBuild: String

    func run() async throws {
        let url = URL(fileURLWithPath: ipswPath)
        let identity = try await IPSWScanner().recordedIdentity(ipswPath: url)
        guard identity.osVersion == expectedVersion, identity.buildNumber == expectedBuild else {
            printError(
                "\(url.lastPathComponent) records \(identity.osVersion) (\(identity.buildNumber)), "
                    + "expected \(expectedVersion) (\(expectedBuild))"
            )
            throw ExitCode.failure
        }
        printLine("\(url.lastPathComponent) records \(identity.osVersion) (\(identity.buildNumber))")
    }
}
