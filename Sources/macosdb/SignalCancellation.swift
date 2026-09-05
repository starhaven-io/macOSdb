import Darwin
import Dispatch
import Foundation

enum SignalCancellation {
    private static let signals: [Int32] = [SIGINT, SIGTERM]

    static func run(
        onFirstSignal: (@Sendable (Int32) -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let taskState = SignalOperationState()
        let monitor = SignalCancellationMonitor(signals: signals) { signalNumber in
            onFirstSignal?(signalNumber)
            taskState.cancel()
        }
        defer { monitor.cancel() }

        let task = Task {
            try await operation()
        }
        taskState.install(task)

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private final class SignalOperationState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var cancellationRequested = false

    func install(_ task: Task<Void, Error>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private final class SignalCancellationMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let signals: [Int32]
    private var previousHandlers: [Int32: sig_t] = [:]
    private var sources: [DispatchSourceSignal] = []
    private var didReceiveSignal = false
    private var isCancelled = false

    init(signals: [Int32], onFirstSignal: @escaping @Sendable (Int32) -> Void) {
        self.signals = signals

        for signalNumber in signals {
            if let previousHandler = Darwin.signal(signalNumber, SIG_IGN) {
                previousHandlers[signalNumber] = previousHandler
            }
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                self?.handleSignal(signalNumber, onFirstSignal: onFirstSignal)
            }
            sources.append(source)
            source.resume()
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let sourcesToCancel = sources
        lock.unlock()

        for source in sourcesToCancel {
            source.cancel()
        }
        restoreSignalHandlers()
    }

    private func handleSignal(_ signalNumber: Int32, onFirstSignal: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        let isFirstSignal = !didReceiveSignal
        didReceiveSignal = true
        lock.unlock()

        if isFirstSignal {
            onFirstSignal(signalNumber)
        } else {
            restoreSignalHandlers()
            Darwin.raise(signalNumber)
        }
    }

    private func restoreSignalHandlers() {
        let handlers: [Int32: sig_t]
        lock.lock()
        handlers = previousHandlers
        lock.unlock()

        for signalNumber in signals {
            Darwin.signal(signalNumber, handlers[signalNumber] ?? SIG_DFL)
        }
    }
}
