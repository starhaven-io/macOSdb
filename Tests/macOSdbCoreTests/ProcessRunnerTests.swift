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

    @Test("Spawned tools receive a readable null standard input")
    func standardInputIsOpen() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "if [[ -r /dev/fd/0 ]]; then printf open; else printf closed; fi"]
        )

        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "open")
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
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(20))
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
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(5))
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

    @Test("Captured output is bounded before it is loaded into memory")
    func capturedOutputIsBounded() async {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                gracePeriod: 0.2,
                maxCapturedOutputBytes: 1_024
            )
            Issue.record("expected oversized output to be rejected")
        } catch ScannerError.processOutputTooLarge(let tool, let limit) {
            #expect(tool == "yes")
            #expect(limit == 1_024)
        } catch {
            Issue.record("expected processOutputTooLarge, got \(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("Output overflow terminates descendants in the spawned process group")
    func outputOverflowTerminatesDescendants() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-process-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidURL) }

        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    """
                    /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "$1"; exec /bin/sleep 30' child "$1" &
                    while [[ ! -s "$1" ]]; do /bin/sleep 0.01; done
                    exec /usr/bin/yes
                    """,
                    "macosdb-process-group-test",
                    pidURL.path
                ],
                gracePeriod: 0.2,
                maxCapturedOutputBytes: 1_024
            )
            Issue.record("expected oversized output to be rejected")
        } catch ScannerError.processOutputTooLarge {
            // Expected.
        }

        let childPIDString = try String(contentsOf: pidURL, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDString))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(childPID, 0) == 0, ContinuousClock.now < deadline {
            usleep(10_000)
        }
        #expect(kill(childPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("A successful leader does not leave captured-output descendants running")
    func successfulLeaderTerminatesDescendants() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-process-success-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidURL) }

        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "/bin/sleep 30 & printf '%s' \"$!\" > \"$1\"; printf 'done\\n'",
                "macosdb-process-success-test",
                pidURL.path
            ],
            gracePeriod: 0.2
        )

        #expect(result.terminationStatus == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "done\n")
        #expect(ContinuousClock.now - start < .seconds(5))

        let childPIDString = try String(contentsOf: pidURL, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDString))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(childPID, 0) == 0, ContinuousClock.now < deadline {
            usleep(10_000)
        }
        #expect(kill(childPID, 0) == -1)
        #expect(errno == ESRCH)
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
