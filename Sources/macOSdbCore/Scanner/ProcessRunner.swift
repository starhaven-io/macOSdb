import Darwin
import Foundation

struct ProcessRunResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

enum ProcessRunner {
    /// Runs an external tool to completion and captures its output.
    ///
    /// Output is captured to temporary files (not pipes) so a chatty tool cannot
    /// deadlock on a full pipe buffer. When `timeout` is set, a process still
    /// running after the deadline is sent SIGTERM — then SIGKILL if it does not
    /// exit within a short grace period — and `ScannerError.processTimedOut` is
    /// thrown, so a hung `hdiutil`/`aea`/`xip` cannot wedge a scan indefinitely.
    /// Cancelled tasks use the same SIGTERM/SIGKILL path, then throw
    /// `CancellationError` after the subprocess exits.
    /// Pass `respectsCancellation: false` for teardown subprocesses that must run
    /// even after the parent scan task has been cancelled.
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        capturesStandardOutput: Bool = true,
        capturesStandardError: Bool = true,
        timeout: TimeInterval? = nil,
        respectsCancellation: Bool = true
    ) async throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = capturesStandardOutput ? try TemporaryOutputCapture(suffix: "stdout") : nil
        let stderr = capturesStandardError ? try TemporaryOutputCapture(suffix: "stderr") : nil

        process.standardOutput = stdout?.fileHandle ?? FileHandle.nullDevice
        process.standardError = stderr?.fileHandle ?? FileHandle.nullDevice

        let state = ProcessRunState(gracePeriod: terminationGracePeriod)
        state.install(process)
        process.terminationHandler = { [weak state] _ in state?.markExited() }

        return try await withTaskCancellationHandler {
            if respectsCancellation {
                try Task.checkCancellation()
            }
            try process.run()
            state.markStarted()

            let timeoutTask = timeout.map { timeout in
                Task.detached {
                    try? await Task.sleep(nanoseconds: nanoseconds(for: timeout))
                    guard !Task.isCancelled else { return }
                    state.requestTermination(reason: .timeout)
                }
            }
            defer { timeoutTask?.cancel() }

            await state.waitUntilExit()

            if respectsCancellation {
                try Task.checkCancellation()
            }
            if state.terminationReason == .timeout {
                throw ScannerError.processTimedOut(
                    tool: executableURL.lastPathComponent,
                    seconds: Int((timeout ?? 0).rounded())
                )
            }

            return ProcessRunResult(
                terminationStatus: process.terminationStatus,
                stdout: try stdout?.readData() ?? Data(),
                stderr: try stderr?.readData() ?? Data()
            )
        } onCancel: {
            if respectsCancellation {
                state.requestTermination(reason: .cancellation)
            }
        }
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    /// How long to wait for a SIGTERM'd process to exit before escalating to SIGKILL.
    private static let terminationGracePeriod: TimeInterval = 10
}

private enum ProcessTerminationReason {
    case timeout
    case cancellation
}

private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let gracePeriod: TimeInterval

    private var process: Process?
    private var isStarted = false
    private var isExited = false
    private var didSendTermination = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var terminationReason: ProcessTerminationReason? {
        lock.lock()
        defer { lock.unlock() }
        return lockedTerminationReason
    }

    private var lockedTerminationReason: ProcessTerminationReason?

    init(gracePeriod: TimeInterval) {
        self.gracePeriod = gracePeriod
    }

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func markStarted() {
        let pendingReason: ProcessTerminationReason?
        lock.lock()
        isStarted = true
        pendingReason = lockedTerminationReason
        lock.unlock()

        if let pendingReason {
            requestTermination(reason: pendingReason)
        }
    }

    func markExited() {
        let waitersToResume: [CheckedContinuation<Void, Never>]
        lock.lock()
        isExited = true
        process = nil
        waitersToResume = waiters
        waiters = []
        lock.unlock()

        for waiter in waitersToResume {
            waiter.resume()
        }
    }

    func waitUntilExit() async {
        await withCheckedContinuation { continuation in
            let shouldResume: Bool
            lock.lock()
            if isExited {
                shouldResume = true
            } else {
                shouldResume = false
                waiters.append(continuation)
            }
            lock.unlock()

            if shouldResume {
                continuation.resume()
            }
        }
    }

    func requestTermination(reason: ProcessTerminationReason) {
        let processToTerminate: Process?
        lock.lock()
        guard !isExited else {
            lock.unlock()
            return
        }

        if lockedTerminationReason == nil {
            lockedTerminationReason = reason
        }

        guard isStarted, !didSendTermination else {
            lock.unlock()
            return
        }

        didSendTermination = true
        processToTerminate = process
        lock.unlock()

        processToTerminate?.terminate()
        scheduleKillIfNeeded()
    }

    private func scheduleKillIfNeeded() {
        Task.detached { [gracePeriod] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, gracePeriod) * 1_000_000_000))
            self.killIfStillRunning()
        }
    }

    private func killIfStillRunning() {
        let pid: pid_t?
        lock.lock()
        if isExited {
            pid = nil
        } else {
            pid = process?.processIdentifier
        }
        lock.unlock()

        if let pid {
            kill(pid, SIGKILL)
        }
    }
}

private final class TemporaryOutputCapture {
    let fileHandle: FileHandle
    private let url: URL

    init(suffix: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-process-\(UUID().uuidString)-\(suffix)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: url)
    }

    func readData() throws -> Data {
        try fileHandle.close()
        return try Data(contentsOf: url)
    }
}
