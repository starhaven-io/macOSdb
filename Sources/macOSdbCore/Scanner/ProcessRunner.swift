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
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        capturesStandardOutput: Bool = true,
        capturesStandardError: Bool = true,
        timeout: TimeInterval? = nil
    ) throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = capturesStandardOutput ? try TemporaryOutputCapture(suffix: "stdout") : nil
        let stderr = capturesStandardError ? try TemporaryOutputCapture(suffix: "stderr") : nil

        process.standardOutput = stdout?.fileHandle ?? FileHandle.nullDevice
        process.standardError = stderr?.fileHandle ?? FileHandle.nullDevice

        // terminationHandler + a semaphore gives us a bounded wait that
        // waitUntilExit() cannot. The handler signals once the process exits,
        // whether it finished on its own or we killed it.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                terminate(process, awaiting: exited)
                throw ScannerError.processTimedOut(
                    tool: executableURL.lastPathComponent,
                    seconds: Int(timeout.rounded())
                )
            }
            // Exited within the deadline — the handler already signalled `exited`.
        } else {
            exited.wait()
        }

        return ProcessRunResult(
            terminationStatus: process.terminationStatus,
            stdout: try stdout?.readData() ?? Data(),
            stderr: try stderr?.readData() ?? Data()
        )
    }

    /// SIGTERM, then SIGKILL after a grace period, ensuring the process is reaped
    /// so the semaphore is always signalled before we return.
    private static func terminate(_ process: Process, awaiting exited: DispatchSemaphore) {
        process.terminate() // SIGTERM
        if exited.wait(timeout: .now() + terminationGracePeriod) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
    }

    /// How long to wait for a SIGTERM'd process to exit before escalating to SIGKILL.
    private static let terminationGracePeriod: TimeInterval = 10
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
