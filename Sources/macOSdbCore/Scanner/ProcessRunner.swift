import Darwin
import Foundation

struct ProcessRunResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

enum ProcessRunner {
    /// Runs an external tool in an isolated process group and captures bounded output.
    ///
    /// Output is drained continuously so a chatty tool cannot deadlock or exhaust
    /// temporary-disk space. Timeout, cancellation, and output overflow terminate
    /// the entire process group, including descendants that retain a capture pipe.
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
        gracePeriod: TimeInterval = terminationGracePeriod,
        maxCapturedOutputBytes: Int = 16 * 1_024 * 1_024
    ) async throws -> ProcessRunResult {
        precondition(maxCapturedOutputBytes >= 0, "captured-output limit must not be negative")

        let state = ProcessRunState(gracePeriod: gracePeriod)
        let overflow: @Sendable () -> Void = {
            state.requestTermination(reason: .outputTooLarge)
        }
        let stdout = capturesStandardOutput
            ? try BoundedOutputCapture(maxBytes: maxCapturedOutputBytes, onOverflow: overflow)
            : nil
        let stderr = capturesStandardError
            ? try BoundedOutputCapture(maxBytes: maxCapturedOutputBytes, onOverflow: overflow)
            : nil
        let context = ExecutionContext(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            timeout: timeout,
            respectsCancellation: respectsCancellation,
            maxCapturedOutputBytes: maxCapturedOutputBytes,
            state: state,
            stdout: stdout,
            stderr: stderr
        )
        return try await withTaskCancellationHandler {
            try await execute(context)
        } onCancel: {
            if respectsCancellation {
                state.requestTermination(reason: .cancellation)
            }
        }
    }

    private static func execute(_ context: ExecutionContext) async throws -> ProcessRunResult {
        if context.respectsCancellation {
            try Task.checkCancellation()
        }
        let pid = try startProcess(context)
        context.state.markStarted(pid: pid)
        context.stdout?.startReading()
        context.stderr?.startReading()
        context.stdout?.closeParentWriter()
        context.stderr?.closeParentWriter()
        waitForExit(of: pid, state: context.state)

        let timeoutWatchdog = context.timeout.map { timeout in
            ProcessWatchdog(
                deadline: .now() + max(0, timeout),
                name: "macOSdb process timeout"
            ) {
                context.state.requestTermination(reason: .timeout)
            }
        }
        defer { timeoutWatchdog?.cancel() }

        await context.state.waitUntilExit()
        let stdoutResult = context.stdout?.finish() ?? .empty
        let stderrResult = context.stderr?.finish() ?? .empty
        try validateCompletion(context, stdout: stdoutResult, stderr: stderrResult)
        return ProcessRunResult(
            terminationStatus: context.state.terminationStatus,
            stdout: stdoutResult.data,
            stderr: stderrResult.data
        )
    }

    private static func startProcess(_ context: ExecutionContext) throws -> pid_t {
        do {
            return try spawn(
                executableURL: context.executableURL,
                arguments: context.arguments,
                currentDirectoryURL: context.currentDirectoryURL,
                stdout: context.stdout,
                stderr: context.stderr
            )
        } catch {
            context.stdout?.abortBeforeStart()
            context.stderr?.abortBeforeStart()
            throw error
        }
    }

    private static func validateCompletion(
        _ context: ExecutionContext,
        stdout: CapturedOutput,
        stderr: CapturedOutput
    ) throws {
        if context.respectsCancellation {
            try Task.checkCancellation()
        }
        switch context.state.terminationReason {
        case .timeout:
            throw ScannerError.processTimedOut(
                tool: context.executableURL.lastPathComponent,
                seconds: Int((context.timeout ?? 0).rounded())
            )
        case .outputTooLarge:
            throw ScannerError.processOutputTooLarge(
                tool: context.executableURL.lastPathComponent,
                limit: context.maxCapturedOutputBytes
            )
        case .cancellation:
            throw CancellationError()
        case nil:
            break
        }
        guard !stdout.exceededLimit, !stderr.exceededLimit else {
            throw ScannerError.processOutputTooLarge(
                tool: context.executableURL.lastPathComponent,
                limit: context.maxCapturedOutputBytes
            )
        }
    }

    private struct ExecutionContext {
        let executableURL: URL
        let arguments: [String]
        let currentDirectoryURL: URL?
        let timeout: TimeInterval?
        let respectsCancellation: Bool
        let maxCapturedOutputBytes: Int
        let state: ProcessRunState
        let stdout: BoundedOutputCapture?
        let stderr: BoundedOutputCapture?
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        stdout: BoundedOutputCapture?,
        stderr: BoundedOutputCapture?
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }

        if let currentDirectoryURL {
            try addWorkingDirectory(currentDirectoryURL.path, to: &actions)
        }
        try configure(stdout, as: STDOUT_FILENO, actions: &actions)
        try configure(stderr, as: STDERR_FILENO, actions: &actions)
        // Add this last because a capture pipe may have reused descriptor 0 when
        // the parent process started without standard input.
        try check(posix_spawn_file_actions_addopen(
            &actions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
        ))

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM] {
            sigaddset(&defaultSignals, signal)
        }
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        try check(posix_spawnattr_setsigmask(&attributes, &signalMask))
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        try check(posix_spawnattr_setflags(&attributes, flags))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let executable = executableURL.path
        let environment = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        return try withCStringArray([executable] + arguments) { argv in
            try withCStringArray(environment) { environmentPointer in
                var pid: pid_t = 0
                try check(posix_spawn(
                    &pid,
                    executable,
                    &actions,
                    &attributes,
                    argv,
                    environmentPointer
                ))
                return pid
            }
        }
    }

    private static func configure(
        _ capture: BoundedOutputCapture?,
        as target: Int32,
        actions: inout posix_spawn_file_actions_t?
    ) throws {
        guard let capture else {
            try check(posix_spawn_file_actions_addopen(
                &actions,
                target,
                "/dev/null",
                O_WRONLY,
                0
            ))
            return
        }

        try check(posix_spawn_file_actions_addclose(&actions, capture.readDescriptor))
        try check(posix_spawn_file_actions_adddup2(&actions, capture.writeDescriptor, target))
        if capture.writeDescriptor != target {
            try check(posix_spawn_file_actions_addclose(&actions, capture.writeDescriptor))
        }
    }

    private static func addWorkingDirectory(
        _ path: String,
        to actions: inout posix_spawn_file_actions_t?
    ) throws {
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, path))
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, path))
        }
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers = try strings.map { string -> UnsafeMutablePointer<CChar>? in
            guard let pointer = strdup(string) else { throw POSIXError(.ENOMEM) }
            return pointer
        }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { throw POSIXError(.EINVAL) }
            return try body(baseAddress)
        }
    }

    private static func waitForExit(of pid: pid_t, state: ProcessRunState) {
        let thread = Thread {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, 0)
            } while result == -1 && errno == EINTR

            let terminationStatus: Int32
            if result == pid {
                let signal = status & 0x7F
                terminationStatus = signal == 0 ? (status >> 8) & 0xFF : signal
            } else {
                terminationStatus = -1
            }
            state.markExited(terminationStatus: terminationStatus)
        }
        thread.name = "macOSdb process waiter"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private static let terminationGracePeriod: TimeInterval = 10
}
