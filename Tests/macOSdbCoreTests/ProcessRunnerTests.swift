import Darwin
import Foundation
import Testing

@testable import macOSdbCore

@Suite("ProcessRunner timeouts", .serialized)
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

    @Test("Process watchdog fires on its dedicated thread")
    func processWatchdogFires() {
        let fired = DispatchSemaphore(value: 0)
        let watchdog = ProcessWatchdog(
            deadline: .now() + .milliseconds(50),
            name: "macOSdb watchdog test"
        ) {
            fired.signal()
        }

        #expect(fired.wait(timeout: .now() + .seconds(10)) == .success)
        withExtendedLifetime(watchdog) {}
    }

    @Test("Process watchdog cancellation prevents its action")
    func processWatchdogCancellation() async {
        let fired = LockedFlag()
        let watchdog = ProcessWatchdog(
            deadline: .now() + .milliseconds(50),
            name: "macOSdb watchdog cancellation test"
        ) {
            fired.set()
        }

        watchdog.cancel()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(!fired.isSet)
    }

    @Test("A process that overruns its timeout is terminated and reported")
    func timesOutAndTerminatesTheProcess() async {
        let start = ContinuousClock.now
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
        #expect(ContinuousClock.now - start < .seconds(20))
        guard case .processTimedOut = thrown as? ScannerError else {
            Issue.record("expected ScannerError.processTimedOut, got \(String(describing: thrown))")
            return
        }
    }

    @Test("Timeout escalates to SIGKILL when a process ignores SIGTERM")
    func timeoutEscalatesToSIGKILL() async {
        let start = ContinuousClock.now
        let readyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-process-ignore-term-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyURL) }

        var thrown: (any Error)?
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; printf ready > \"$1\"; exec /bin/sleep 30",
                    "macosdb-escalation-test",
                    readyURL.path
                ],
                timeout: 1,
                gracePeriod: 0.2
            )
        } catch {
            thrown = error
        }

        #expect(FileManager.default.fileExists(atPath: readyURL.path))
        #expect(ContinuousClock.now - start < .seconds(5))
        guard case .processTimedOut = thrown as? ScannerError else {
            Issue.record("expected ScannerError.processTimedOut, got \(String(describing: thrown))")
            return
        }
    }

    @Test("Cancellation terminates a running process")
    func cancellationTerminatesTheProcess() async {
        let start = ContinuousClock.now
        let readyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-process-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyURL) }

        let task = Task {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf ready > \"$1\"; exec /bin/sleep 30",
                    "macosdb-cancellation-test",
                    readyURL.path
                ],
                timeout: 30
            )
        }

        let readyPath = readyURL.path
        let cancellationThread = Thread {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while access(readyPath, F_OK) != 0, ContinuousClock.now < deadline {
                usleep(10_000)
            }
            task.cancel()
        }
        cancellationThread.name = "macOSdb cancellation test"
        cancellationThread.start()

        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: readyPath))
        #expect(ContinuousClock.now - start < .seconds(20))
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

        task.cancel()

        let result = try await task.value
        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "done\n")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}
