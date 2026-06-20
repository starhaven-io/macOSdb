import Foundation
import Testing

@testable import macOSdbKit

@Suite("ProcessRunner timeouts")
struct ProcessRunnerTests {

    @Test("Captures output when no timeout is set")
    func capturesOutputWithoutTimeout() throws {
        let result = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"]
        )

        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "hello\n")
    }

    @Test("A process that finishes inside its timeout succeeds normally")
    func capturesOutputWithinTimeout() throws {
        let result = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hi"],
            timeout: 10
        )

        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "hi\n")
    }

    @Test("A process that overruns its timeout is terminated and reported")
    func timesOutAndTerminatesTheProcess() {
        let start = Date()
        var thrown: (any Error)?
        do {
            _ = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 1
            )
        } catch {
            thrown = error
        }

        // It must return far sooner than the 30s the process would otherwise sleep.
        #expect(Date().timeIntervalSince(start) < 20)
        guard case .processTimedOut = thrown as? ScannerError else {
            Issue.record("expected ScannerError.processTimedOut, got \(String(describing: thrown))")
            return
        }
    }
}
