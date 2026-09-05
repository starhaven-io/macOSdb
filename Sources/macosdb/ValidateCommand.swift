import ArgumentParser
import CryptoKit
import Darwin
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
        let archive: OpenedArchive
        do {
            archive = try OpenedArchive(url: url)
        } catch {
            printStatus("\(url.lastPathComponent)  (unreadable)")
            printStatus("  ✗ Invalid archive file: \(error.localizedDescription)")
            return .failed
        }
        let sizeGB = String(format: "%.1f GB", Double(archive.fileSize) / 1e9)

        let sidecar = url.appendingPathExtension("sha256")
        let sidecarState = rehash ? .missing : storedHash(at: sidecar, archiveName: url.lastPathComponent)

        printStatus("\(url.lastPathComponent)  (\(sizeGB))")

        if url.pathExtension.lowercased() == "ipsw" {
            do {
                let entryCount = try validateZIP(archive)
                try archive.ensurePathStillReferencesOpenedFile()
                printStatus("  ✓ Valid ZIP  (\(entryCount) entries)")
            } catch {
                printStatus("  ✗ Invalid ZIP: \(error.localizedDescription)")
                return .failed
            }
        }

        let digest: String
        do {
            digest = try hashFile(archive)
            try archive.ensurePathStillReferencesOpenedFile()
        } catch {
            printStatus("  ✗ Hashing failed: \(error.localizedDescription)")
            return .failed
        }

        let existingHash: String?
        switch sidecarState {
        case .missing:
            existingHash = nil
        case .valid(let hash):
            existingHash = hash
        case .invalid(let reason):
            printStatus("  ✗ Invalid sidecar: \(reason) (use --rehash to replace it)")
            return .failed
        }

        if let existingHash {
            return verify(existingHash, computed: digest, archive: archive)
        }

        // Create (or rewrite, with --rehash) the sidecar.
        do {
            try writeSidecar(digest: digest, archive: archive, archiveURL: url, sidecar: sidecar)
            printStatus("  ✓ sha256: \(digest)")
            printStatus("    → \(sidecar.lastPathComponent)")
        } catch {
            printStatus("  ✗ Writing sidecar failed: \(error.localizedDescription)")
            return .failed
        }

        return .hashed
    }

    private func verify(_ stored: String, computed: String, archive: OpenedArchive) -> ProcessResult {
        guard stored == computed else {
            printStatus("  ✗ MISMATCH  stored \(stored)  computed \(computed)")
            return .failed
        }
        do {
            try archive.ensurePathStillReferencesOpenedFile()
        } catch {
            printStatus("  ✗ Archive changed during validation: \(error.localizedDescription)")
            return .failed
        }
        printStatus("  ✓ verified: \(computed)")
        return .verified
    }

    private func writeSidecar(
        digest: String,
        archive: OpenedArchive,
        archiveURL: URL,
        sidecar: URL
    ) throws {
        try archive.ensurePathStillReferencesOpenedFile()
        let line = "\(digest)  \(archiveURL.lastPathComponent)\n"
        try line.write(to: sidecar, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.modificationDate: archive.modificationDate], ofItemAtPath: sidecar.path
        )
    }

    private enum SidecarState {
        case missing
        case valid(String)
        case invalid(String)
    }

    private static let maxSidecarBytes: off_t = 4 * 1_024

    private func storedHash(at sidecar: URL, archiveName: String) -> SidecarState {
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return .missing }

        let contents: String
        do {
            contents = try readSidecar(sidecar)
        } catch {
            return .invalid("could not safely read \(sidecar.lastPathComponent)")
        }

        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let line = lines.first,
              !line.isEmpty,
              lines.count == 1 || (lines.count == 2 && lines[1].isEmpty) else {
            return .invalid("expected one checksum line")
        }
        let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let hash = fields.first.map(String.init),
              hash.count == 64,
              hash.allSatisfy(\.isHexDigit) else {
            return .invalid("expected a 64-character hexadecimal SHA-256 digest")
        }
        if fields.count == 2 {
            let filename = String(fields[1]).trimmingCharacters(in: .whitespaces)
                .trimmingPrefix("*")
            guard filename == archiveName else {
                return .invalid("checksum names \(filename), not \(archiveName)")
            }
        }
        return .valid(hash.lowercased())
    }

    private func readSidecar(_ url: URL) throws -> String {
        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0,
              pathMetadata.st_mode & S_IFMT == S_IFREG,
              pathMetadata.st_size >= 0,
              pathMetadata.st_size <= Self.maxSidecarBytes else {
            throw OpenedArchiveError.notRegularFile
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var descriptorMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0,
              descriptorMetadata.st_mode & S_IFMT == S_IFREG,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino,
              descriptorMetadata.st_size <= Self.maxSidecarBytes else {
            throw OpenedArchiveError.identityChanged
        }
        guard let data = try handle.read(upToCount: Int(Self.maxSidecarBytes) + 1),
              data.count <= Int(Self.maxSidecarBytes),
              let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return contents
    }

    private func validateZIP(_ openedArchive: OpenedArchive) throws -> Int {
        let archive = try Archive(url: openedArchive.descriptorURL, accessMode: .read)
        return archive.reduce(0) { count, _ in count + 1 }
    }

    private func hashFile(_ archive: OpenedArchive) throws -> String {
        let bufSize = 8 * 1_024 * 1_024
        let fileSize = archive.fileSize
        let handle = archive.handle
        try handle.seek(toOffset: 0)

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
                let pct = Int64(bytesRead) * 100 / fileSize
                if interactive {
                    printInline("  Hashing... \(pct)%")
                } else if Int(pct / 10) != lastDecile {
                    lastDecile = Int(pct / 10)
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

final class OpenedArchive {
    let url: URL
    let handle: FileHandle
    let fileSize: Int64
    let modificationDate: Date

    var descriptorURL: URL {
        URL(fileURLWithPath: "/dev/fd/\(handle.fileDescriptor)")
    }

    private let identity: Identity

    init(url: URL) throws {
        self.url = url

        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard pathMetadata.st_mode & S_IFMT == S_IFREG else {
            throw OpenedArchiveError.notRegularFile
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var descriptorMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard descriptorMetadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw OpenedArchiveError.notRegularFile
        }

        identity = Identity(descriptorMetadata)
        fileSize = descriptorMetadata.st_size
        modificationDate = Date(
            timeIntervalSince1970: TimeInterval(descriptorMetadata.st_mtimespec.tv_sec)
                + TimeInterval(descriptorMetadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try ensurePathStillReferencesOpenedFile()
    }

    func ensurePathStillReferencesOpenedFile() throws {
        var descriptorMetadata = stat()
        guard fstat(handle.fileDescriptor, &descriptorMetadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0,
              pathMetadata.st_mode & S_IFMT == S_IFREG,
              Identity(descriptorMetadata) == identity,
              Identity(pathMetadata) == identity else {
            throw OpenedArchiveError.identityChanged
        }
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            size = metadata.st_size
            modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        }
    }
}

enum OpenedArchiveError: LocalizedError {
    case notRegularFile
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            "Archive must be a regular file and not a symbolic link"
        case .identityChanged:
            "Archive pathname or contents changed during validation"
        }
    }
}
