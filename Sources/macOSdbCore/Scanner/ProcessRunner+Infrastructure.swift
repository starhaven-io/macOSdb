import Darwin
import Foundation

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

enum ProcessTerminationReason {
    case timeout
    case cancellation
    case outputTooLarge
}

final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let gracePeriod: TimeInterval

    private var pid: pid_t?
    private var isStarted = false
    private var isExited = false
    private var processGroupIsTerminated = true
    private var didSendTermination = false
    private var status: Int32 = -1
    private var terminator: ProcessGroupTerminator?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lockedTerminationReason: ProcessTerminationReason?

    var terminationReason: ProcessTerminationReason? {
        lock.withLock { lockedTerminationReason }
    }

    var terminationStatus: Int32 {
        lock.withLock { status }
    }

    init(gracePeriod: TimeInterval) {
        self.gracePeriod = gracePeriod
    }

    func markStarted(pid: pid_t) {
        let pendingReason: ProcessTerminationReason?
        lock.lock()
        self.pid = pid
        isStarted = true
        processGroupIsTerminated = false
        pendingReason = lockedTerminationReason
        lock.unlock()

        if let pendingReason {
            requestTermination(reason: pendingReason)
        }
    }

    func markExited(terminationStatus: Int32) {
        let processGroupToKill: pid_t?
        let terminatorToCancel: ProcessGroupTerminator?
        let waitersToResume: [CheckedContinuation<Void, Never>]
        lock.lock()
        isExited = true
        status = terminationStatus
        if !processGroupIsTerminated {
            processGroupToKill = pid
            processGroupIsTerminated = true
            terminatorToCancel = terminator
            terminator = nil
        } else {
            processGroupToKill = nil
            terminatorToCancel = nil
        }
        waitersToResume = takeWaitersIfComplete()
        lock.unlock()

        if let processGroupToKill {
            signalProcessGroup(processGroupToKill, signal: SIGKILL)
        }
        terminatorToCancel?.cancel()
        resume(waitersToResume)
    }

    func waitUntilExit() async {
        await withCheckedContinuation { continuation in
            let shouldResume: Bool
            lock.lock()
            if isComplete {
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
        let processIdentifier: pid_t?
        lock.lock()
        if lockedTerminationReason == nil {
            lockedTerminationReason = reason
        }
        guard isStarted, !didSendTermination, !isExited else {
            lock.unlock()
            return
        }

        didSendTermination = true
        processGroupIsTerminated = false
        processIdentifier = pid
        lock.unlock()

        guard let processIdentifier else { return }
        signalProcessGroup(processIdentifier, signal: SIGTERM)
        let terminator = ProcessGroupTerminator(
            processGroup: processIdentifier,
            gracePeriod: gracePeriod
        ) { [weak self] in
            self?.markProcessGroupTerminated()
        }
        lock.withLock { self.terminator = terminator }
        terminator.start()
    }

    private var isComplete: Bool {
        isExited && processGroupIsTerminated
    }

    private func takeWaitersIfComplete() -> [CheckedContinuation<Void, Never>] {
        guard isComplete else { return [] }
        let result = waiters
        waiters = []
        return result
    }

    private func markProcessGroupTerminated() {
        let waitersToResume: [CheckedContinuation<Void, Never>]
        lock.lock()
        processGroupIsTerminated = true
        terminator = nil
        waitersToResume = takeWaitersIfComplete()
        lock.unlock()
        resume(waitersToResume)
    }

    private func resume(_ continuations: [CheckedContinuation<Void, Never>]) {
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class ProcessGroupTerminator: @unchecked Sendable {
    private let processGroup: pid_t
    private let gracePeriod: TimeInterval
    private let completion: @Sendable () -> Void
    private let cancellation = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(
        processGroup: pid_t,
        gracePeriod: TimeInterval,
        completion: @escaping @Sendable () -> Void
    ) {
        self.processGroup = processGroup
        self.gracePeriod = gracePeriod
        self.completion = completion
    }

    func start() {
        let thread = Thread { [processGroup, gracePeriod, completion, cancellation] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, gracePeriod)))
            while processGroupExists(processGroup), ContinuousClock.now < deadline {
                if cancellation.wait(timeout: .now() + .milliseconds(10)) == .success {
                    return
                }
            }
            if processGroupExists(processGroup) {
                signalProcessGroup(processGroup, signal: SIGKILL)
            }
            completion()
        }
        self.thread = thread
        thread.name = "macOSdb process-group terminator"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancel() {
        cancellation.signal()
    }
}

struct CapturedOutput {
    static let empty = Self(data: Data(), exceededLimit: false)

    let data: Data
    let exceededLimit: Bool
}

final class BoundedOutputCapture: @unchecked Sendable {
    let readDescriptor: Int32
    let writeDescriptor: Int32

    private let readHandle: FileHandle
    private let writeHandle: FileHandle
    private let maxBytes: Int
    private let onOverflow: @Sendable () -> Void
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)

    private var captured = Data()
    private var exceededLimit = false
    private var shouldStop = false
    private var thread: Thread?

    init(maxBytes: Int, onOverflow: @escaping @Sendable () -> Void) throws {
        let pipe = Pipe()
        readHandle = pipe.fileHandleForReading
        writeHandle = pipe.fileHandleForWriting
        readDescriptor = readHandle.fileDescriptor
        writeDescriptor = writeHandle.fileDescriptor
        self.maxBytes = maxBytes
        self.onOverflow = onOverflow

        let currentFlags = fcntl(readDescriptor, F_GETFL)
        guard currentFlags != -1, fcntl(readDescriptor, F_SETFL, currentFlags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func startReading() {
        let thread = Thread { [weak self] in
            self?.readUntilStopped()
        }
        self.thread = thread
        thread.name = "macOSdb bounded output capture"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func closeParentWriter() {
        try? writeHandle.close()
    }

    func abortBeforeStart() {
        try? writeHandle.close()
        try? readHandle.close()
    }

    func finish() -> CapturedOutput {
        lock.withLock { shouldStop = true }
        finished.wait()
        try? readHandle.close()
        thread = nil
        return lock.withLock {
            CapturedOutput(data: captured, exceededLimit: exceededLimit)
        }
    }

    private func readUntilStopped() {
        defer { finished.signal() }
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)

        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                read(readDescriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                consume(bytes, count: count)
                continue
            }
            if count == 0 || (count == -1 && errno != EAGAIN && errno != EINTR) {
                return
            }
            if count == -1, errno == EINTR {
                continue
            }
            if lock.withLock({ shouldStop }) {
                return
            }

            var descriptor = pollfd(fd: readDescriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 100)
        }
    }

    private func consume(_ bytes: [UInt8], count: Int) {
        var reportOverflow = false
        lock.lock()
        let remaining = max(0, maxBytes - captured.count)
        if remaining > 0 {
            captured.append(contentsOf: bytes.prefix(min(remaining, count)))
        }
        if count > remaining, !exceededLimit {
            exceededLimit = true
            reportOverflow = true
        }
        lock.unlock()

        if reportOverflow {
            onOverflow()
        }
    }
}

private func signalProcessGroup(_ processGroup: pid_t, signal: Int32) {
    _ = kill(-processGroup, signal)
}

private func processGroupExists(_ processGroup: pid_t) -> Bool {
    kill(-processGroup, 0) == 0 || errno == EPERM
}
