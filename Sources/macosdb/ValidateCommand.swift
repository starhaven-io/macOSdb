import ArgumentParser
import CryptoKit
import Foundation
import ZIPFoundation

struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate IPSW files and verify or create SHA-256 sidecar hashes."
    )

    @Argument(help: "IPSW file(s) to validate.")
    var ipswPaths: [String] = []

    @Option(name: .shortAndLong, help: "Directory to search recursively for .ipsw files.")
    var dir: String?

    @Flag(name: .long, help: "Rewrite sidecar even if one already exists.")
    var rehash = false

    func validate() throws {
        if ipswPaths.isEmpty && dir == nil {
            throw ValidationError("Provide at least one IPSW path or --dir.")
        }
    }

    func run() async throws {
        let targets = collectTargets()

        if targets.isEmpty {
            printStatus("No .ipsw files found.")
            throw ExitCode.failure
        }

        printStatus("Validating \(targets.count) IPSW(s)...\n")

        var passed = 0
        var failed = 0

        for url in targets {
            let ok = await process(url)
            ok ? (passed += 1) : (failed += 1)
        }

        printStatus("\n\(passed) passed\(failed > 0 ? ", \(failed) failed" : "")  (\(targets.count) total)")

        if failed > 0 {
            throw ExitCode.failure
        }
    }

    @discardableResult
    private func process(_ url: URL) async -> Bool {
        let sizeGB = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "unknown size"

        printStatus("\(url.lastPathComponent)  (\(sizeGB))")

        do {
            let entryCount = try validateZIP(at: url)
            printStatus("  ✓ Valid ZIP  (\(entryCount) entries)")
        } catch {
            printStatus("  ✗ Invalid ZIP: \(error.localizedDescription)")
            return false
        }

        let sidecar = url.appendingPathExtension("sha256")
        do {
            let digest = try await hashFile(url)

            if sidecar.isReadableFile && !rehash {
                let existing = (try? String(contentsOf: sidecar, encoding: .utf8))?
                    .split(separator: " ").first.map(String.init) ?? ""
                if existing == digest {
                    printStatus("  ✓ sha256: \(digest)")
                } else {
                    printStatus("  ✗ Hash mismatch!")
                    printStatus("    expected: \(existing)")
                    printStatus("    actual:   \(digest)")
                    return false
                }
            } else {
                let line = "\(digest)  \(url.lastPathComponent)\n"
                try line.write(to: sidecar, atomically: true, encoding: .utf8)
                matchMtime(of: sidecar, to: url)
                printStatus("  ✓ sha256: \(digest)")
                printStatus("    → \(sidecar.lastPathComponent)")
            }
        } catch {
            printStatus("  ✗ Hashing failed: \(error.localizedDescription)")
            return false
        }

        return true
    }

    private func validateZIP(at url: URL) throws -> Int {
        let archive = try Archive(url: url, accessMode: .read)
        return archive.reduce(0) { count, _ in count + 1 }
    }

    private func hashFile(_ url: URL) async throws -> String {
        let bufSize = 8 * 1_024 * 1_024
        let fileSize = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = SHA256()
        var bytesRead = 0

        while true {
            let chunk = handle.readData(ofLength: bufSize)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            bytesRead += chunk.count
            if fileSize > 0 {
                let pct = bytesRead * 100 / fileSize
                printInline("  Hashing... \(pct)%")
            }
        }

        printInline("")
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func collectTargets() -> [URL] {
        var urls: [URL] = ipswPaths.map { URL(fileURLWithPath: $0) }

        if let dirPath = dir {
            let dirURL = URL(fileURLWithPath: dirPath)
            let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                if fileURL.pathExtension == "ipsw" {
                    urls.append(fileURL)
                }
            }
            urls.sort { $0.path < $1.path }
        }

        return urls
    }

    private func printStatus(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func printInline(_ message: String) {
        let line = message.isEmpty ? "\r\u{1B}[K" : "\r\(message)"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func matchMtime(of dst: URL, to src: URL) {
        guard let mtime = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return
        }
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: dst.path)
    }
}

private extension URL {
    var isReadableFile: Bool {
        (try? checkResourceIsReachable()) == true
    }
}
