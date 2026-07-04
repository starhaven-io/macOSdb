import ArgumentParser
import CryptoKit
import Foundation
import ZIPFoundation

struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate archive files and verify or create SHA-256 sidecar hashes."
    )

    @Argument(help: "Archive file(s) to validate (.ipsw or .xip).")
    var archivePaths: [String] = []

    @Option(name: .shortAndLong, help: "Directory to search recursively for .ipsw and .xip files.")
    var dir: String?

    @Flag(name: .long, help: "Rewrite sidecar even if one already exists.")
    var rehash = false

    func validate() throws {
        if archivePaths.isEmpty && dir == nil {
            throw ValidationError("Provide at least one archive path or --dir.")
        }
    }

    func run() async throws {
        let targets = collectTargets()

        if targets.isEmpty {
            printStatus("No archive files found.")
            throw ExitCode.failure
        }

        printStatus("Validating \(targets.count) archive(s)...\n")

        var hashed = 0
        var verified = 0
        var failed = 0

        for url in targets {
            let result = await process(url)
            switch result {
            case .hashed: hashed += 1
            case .verified: verified += 1
            case .failed: failed += 1
            }
        }

        let parts = [
            hashed > 0 ? "\(hashed) hashed" : nil,
            verified > 0 ? "\(verified) verified" : nil,
            failed > 0 ? "\(failed) failed" : nil
        ].compactMap { $0 }
        printStatus("\n\(parts.joined(separator: ", "))  (\(targets.count) total)")

        if failed > 0 {
            throw ExitCode.failure
        }
    }

    private enum ProcessResult { case hashed, verified, failed }

    private func process(_ url: URL) async -> ProcessResult {
        let sizeGB = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "unknown size"

        let sidecar = url.appendingPathExtension("sha256")
        let existingHash = rehash ? nil : storedHash(at: sidecar)

        printStatus("\(url.lastPathComponent)  (\(sizeGB))")

        if url.pathExtension.lowercased() == "ipsw" {
            do {
                let entryCount = try validateZIP(at: url)
                printStatus("  ✓ Valid ZIP  (\(entryCount) entries)")
            } catch {
                printStatus("  ✗ Invalid ZIP: \(error.localizedDescription)")
                return .failed
            }
        }

        let digest: String
        do {
            digest = try await hashFile(url)
        } catch {
            printStatus("  ✗ Hashing failed: \(error.localizedDescription)")
            return .failed
        }

        // Verify against the stored sidecar rather than trusting its mere existence.
        if let existingHash {
            guard existingHash == digest else {
                printStatus("  ✗ MISMATCH  stored \(existingHash)  computed \(digest)")
                return .failed
            }
            printStatus("  ✓ verified: \(digest)")
            return .verified
        }

        // Create (or rewrite, with --rehash) the sidecar.
        do {
            let line = "\(digest)  \(url.lastPathComponent)\n"
            try line.write(to: sidecar, atomically: true, encoding: .utf8)
            if let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: sidecar.path)
            }
            printStatus("  ✓ sha256: \(digest)")
            printStatus("    → \(sidecar.lastPathComponent)")
        } catch {
            printStatus("  ✗ Writing sidecar failed: \(error.localizedDescription)")
            return .failed
        }

        return .hashed
    }

    /// Reads the hex digest from an existing `<archive>.sha256` sidecar, if present.
    private func storedHash(at sidecar: URL) -> String? {
        guard let contents = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        return contents.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first
            .map { $0.lowercased() }
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

        // Live percentage redraws in place on a terminal; in a non-TTY log (CI,
        // pipes) carriage returns don't collapse, so fall back to a discrete
        // status line every 10% — scan-style progress, not thousands of lines.
        let interactive = isatty(STDERR_FILENO) != 0
        var hasher = SHA256()
        var bytesRead = 0
        var lastDecile = -1

        while true {
            let chunk = try autoreleasepool {
                try handle.read(upToCount: bufSize)
            }
            guard let chunk, !chunk.isEmpty else { break }

            hasher.update(data: chunk)
            bytesRead += chunk.count
            if fileSize > 0 {
                let pct = bytesRead * 100 / fileSize
                if interactive {
                    printInline("  Hashing... \(pct)%")
                } else if pct / 10 != lastDecile {
                    lastDecile = pct / 10
                    printStatus("  Hashing... \(pct)%")
                }
            }
        }

        if interactive { printInline("") }
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static let supportedExtensions: Set<String> = ["ipsw", "xip"]

    private func collectTargets() -> [URL] {
        var urls: [URL] = archivePaths.map { URL(fileURLWithPath: $0) }

        if let dirPath = dir {
            let dirURL = URL(fileURLWithPath: dirPath)
            let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                if Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    urls.append(fileURL)
                }
            }
            urls.sort { $0.path < $1.path }
        }

        return urls
    }

}
