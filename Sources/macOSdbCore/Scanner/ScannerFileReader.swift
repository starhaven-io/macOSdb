import Darwin
import Foundation

enum ScannerFileReader {
    static let maxBinaryBytes = 256 * 1_024 * 1_024
    static let maxMetadataBytes = 16 * 1_024 * 1_024

    static func data(
        at url: URL,
        confinedTo root: URL,
        maxBytes: Int = maxBinaryBytes
    ) throws -> Data {
        precondition(maxBytes >= 0, "scanner file limit must not be negative")
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = try resolvedPath(at: url, confinedTo: resolvedRoot)
        let descriptor = try openConfined(
            resolved,
            rootedAt: resolvedRoot,
            finalFlags: O_RDONLY
        )
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw currentPOSIXError() }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw ScannerFileReadError.notRegularFile(url.lastPathComponent)
        }
        guard before.st_size >= 0, before.st_size <= off_t(maxBytes) else {
            throw ScannerFileReadError.tooLarge(url.lastPathComponent, maxBytes)
        }

        let data = try read(descriptor, name: url.lastPathComponent, maxBytes: maxBytes)
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw currentPOSIXError() }
        guard FileIdentity(before) == FileIdentity(after) else {
            throw ScannerFileReadError.changed(url.lastPathComponent)
        }
        return data
    }

    static func string(
        at url: URL,
        confinedTo root: URL,
        maxBytes: Int = maxMetadataBytes
    ) throws -> String {
        let data = try data(at: url, confinedTo: root, maxBytes: maxBytes)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ScannerFileReadError.invalidUTF8(url.lastPathComponent)
        }
        return value
    }

    static func fileHandle(at url: URL, confinedTo root: URL) throws -> FileHandle {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = try resolvedPath(at: url, confinedTo: resolvedRoot)
        let descriptor = try openConfined(
            resolved,
            rootedAt: resolvedRoot,
            finalFlags: O_RDONLY
        )

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let error = currentPOSIXError()
            close(descriptor)
            throw error
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw ScannerFileReadError.notRegularFile(url.lastPathComponent)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func resolvedDirectory(at url: URL, confinedTo root: URL) throws -> URL {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = try resolvedPath(at: url, confinedTo: resolvedRoot)
        let descriptor = try openConfined(
            resolved,
            rootedAt: resolvedRoot,
            finalFlags: O_RDONLY | O_DIRECTORY
        )
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw currentPOSIXError() }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ScannerFileReadError.notDirectory(url.lastPathComponent)
        }
        return resolved
    }

    private static func resolvedPath(at url: URL, confinedTo resolvedRoot: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(prefix) else {
            throw ScannerFileReadError.outsideRoot(url.lastPathComponent)
        }
        return resolved
    }

    /// Open each already-resolved path component relative to the root descriptor.
    /// This preserves legitimate in-tree symlinks while preventing a path swap
    /// from redirecting the final open outside the extracted archive.
    private static func openConfined(
        _ resolved: URL,
        rootedAt root: URL,
        finalFlags: Int32
    ) throws -> Int32 {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let relativePath = resolved.path.dropFirst(prefix.count)
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw ScannerFileReadError.outsideRoot(resolved.lastPathComponent)
        }

        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw currentPOSIXError() }
        var descriptors = [rootDescriptor]
        defer {
            for descriptor in descriptors {
                close(descriptor)
            }
        }

        for (index, component) in components.enumerated() {
            let isFinal = index == components.index(before: components.endIndex)
            let flags = O_CLOEXEC | O_NOFOLLOW | (isFinal ? finalFlags : O_RDONLY | O_DIRECTORY)
            let descriptor = component.withCString { pointer in
                openat(descriptors[descriptors.index(before: descriptors.endIndex)], pointer, flags)
            }
            guard descriptor >= 0 else { throw currentPOSIXError() }
            descriptors.append(descriptor)
        }

        guard let result = descriptors.popLast() else {
            throw ScannerFileReadError.outsideRoot(resolved.lastPathComponent)
        }
        return result
    }

    private static func read(_ descriptor: Int32, name: String, maxBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        while true {
            let remaining = maxBytes - data.count
            let requested = min(buffer.count, remaining == Int.max ? remaining : remaining + 1)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count > 0 {
                guard count <= remaining else {
                    throw ScannerFileReadError.tooLarge(name, maxBytes)
                }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            size = metadata.st_size
            modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private enum ScannerFileReadError: LocalizedError {
    case outsideRoot(String)
    case notRegularFile(String)
    case notDirectory(String)
    case tooLarge(String, Int)
    case changed(String)
    case invalidUTF8(String)

    var errorDescription: String? {
        switch self {
        case .outsideRoot(let name):
            "Refusing scanner input outside the extracted archive: \(name)"
        case .notRegularFile(let name):
            "Scanner input is not a regular file: \(name)"
        case .notDirectory(let name):
            "Scanner input is not a directory: \(name)"
        case .tooLarge(let name, let limit):
            "Scanner input \(name) exceeds the \(limit)-byte limit"
        case .changed(let name):
            "Scanner input changed while it was being read: \(name)"
        case .invalidUTF8(let name):
            "Scanner input is not valid UTF-8: \(name)"
        }
    }
}
