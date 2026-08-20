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
        respectsCancellation: Bool = true,
        gracePeriod: TimeInterval = terminationGracePeriod
    ) async throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = capturesStandardOutput ? try TemporaryOutputCapture(suffix: "stdout") : nil
        let stderr = capturesStandardError ? try TemporaryOutputCapture(suffix: "stderr") : nil

        process.standardOutput = stdout?.fileHandle ?? FileHandle.nullDevice
        process.standardError = stderr?.fileHandle ?? FileHandle.nullDevice

        let state = ProcessRunState(gracePeriod: gracePeriod)
        state.install(process)
        process.terminationHandler = { [weak state] _ in state?.markExited() }

        return try await withTaskCancellationHandler {
            if respectsCancellation {
                try Task.checkCancellation()
            }
            try process.run()
            state.markStarted()

            let timeoutWatchdog = timeout.map { timeout in
                ProcessWatchdog(
                    deadline: .now() + max(0, timeout),
                    name: "macOSdb process timeout"
                ) {
                    state.requestTermination(reason: .timeout)
                }
            }
            defer { timeoutWatchdog?.cancel() }

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

    /// How long to wait for a SIGTERM'd process to exit before escalating to SIGKILL.
    private static let terminationGracePeriod: TimeInterval = 10
}

final class ProcessWatchdog: @unchecked Sendable {
    private let cancellation: DispatchSemaphore
    private let thread: Thread

    init(deadline: DispatchTime, name: String, action: @escaping @Sendable () -> Void) {
        let cancellation = DispatchSemaphore(value: 0)
        self.cancellation = cancellation
        self.thread = Thread {
            guard cancellation.wait(timeout: deadline) == .timedOut else { return }
            action()
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancel() {
        cancellation.signal()
    }
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
    private var killWatchdog: ProcessWatchdog?
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
        let killWatchdogToCancel: ProcessWatchdog?
        let waitersToResume: [CheckedContinuation<Void, Never>]
        lock.lock()
        isExited = true
        process = nil
        killWatchdogToCancel = killWatchdog
        killWatchdog = nil
        waitersToResume = waiters
        waiters = []
        lock.unlock()

        killWatchdogToCancel?.cancel()
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
        let watchdog = ProcessWatchdog(
            deadline: .now() + max(0, gracePeriod),
            name: "macOSdb process termination"
        ) { [weak self] in
            self?.killIfStillRunning()
        }

        lock.lock()
        let processAlreadyExited = isExited
        if !processAlreadyExited {
            killWatchdog = watchdog
        }
        lock.unlock()

        if processAlreadyExited {
            watchdog.cancel()
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
