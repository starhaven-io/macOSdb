import Foundation

struct ProcessRunResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

enum ProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        capturesStandardOutput: Bool = true,
        capturesStandardError: Bool = true
    ) throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = capturesStandardOutput ? try TemporaryOutputCapture(suffix: "stdout") : nil
        let stderr = capturesStandardError ? try TemporaryOutputCapture(suffix: "stderr") : nil

        process.standardOutput = stdout?.fileHandle ?? FileHandle.nullDevice
        process.standardError = stderr?.fileHandle ?? FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        return ProcessRunResult(
            terminationStatus: process.terminationStatus,
            stdout: try stdout?.readData() ?? Data(),
            stderr: try stderr?.readData() ?? Data()
        )
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
