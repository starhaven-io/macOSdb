import Foundation
import Testing

@testable import macOSdbCore

@Suite("ProcessRunner timeouts")
struct ProcessRunnerTests {

    @Test("Captures output when no timeout is set")
    func capturesOutputWithoutTimeout() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"]
        )

        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "hello\n")
    }

    @Test("A process that finishes inside its timeout succeeds normally")
    func capturesOutputWithinTimeout() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hi"],
            timeout: 10
        )

        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "hi\n")
    }

    @Test("A process that overruns its timeout is terminated and reported")
    func timesOutAndTerminatesTheProcess() async {
        let start = Date()
        var thrown: (any Error)?
        do {
            _ = try await ProcessRunner.run(
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

    @Test("Cancellation terminates a running process")
    func cancellationTerminatesTheProcess() async {
        let start = Date()
        let task = Task {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 30
            )
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(Date().timeIntervalSince(start) < 20)
    }

    @Test("Cancellation can be ignored for teardown processes")
    func cancellationCanBeIgnoredForTeardownProcesses() async throws {
        let task = Task {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 0.2; echo done"],
                timeout: 10,
                respectsCancellation: false
            )
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let result = try await task.value
        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "done\n")
    }
}
