import Darwin
import Foundation
import Testing

@testable import macosdb

@Suite("signal cancellation tests")
struct SignalCancellationTests {
    @Test("SIGINT cancels the wrapped operation")
    func sigintCancelsWrappedOperation() async {
        // Keep SIGINT non-fatal for the duration of this test. If SignalCancellation.run
        // ever regressed and failed to install its own handler, the raised SIGINT would
        // otherwise hit the default disposition and terminate the whole test process. With
        // this net a regression instead surfaces as a clean "expected CancellationError"
        // failure. The real signal path is still exercised: DispatchSourceSignal delivers
        // regardless of the SIG_IGN disposition.
        let previousHandler = Darwin.signal(SIGINT, SIG_IGN)
        defer { Darwin.signal(SIGINT, previousHandler ?? SIG_DFL) }

        let signalTask = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            Darwin.raise(SIGINT)
        }
        defer { signalTask.cancel() }

        do {
            try await SignalCancellation.run {
                try await Task.sleep(for: .seconds(1))
            }
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }
}
