import Foundation

/// The container an Xcode release ships in, chosen from the archive's file extension.
enum XcodeArchiveFormat: Equatable, Sendable {
    case xip
    case aea

    init(archive: URL) {
        self = archive.pathExtension.lowercased() == "aea" ? .aea : .xip
    }

    /// `xip` accepts no destination and expands into its working directory, so
    /// the caller must run the command inside `workspace` for either format.
    func expansionCommand(
        for archive: URL,
        into workspace: URL
    ) throws -> (executableURL: URL, arguments: [String]) {
        switch self {
        case .xip:
            return (URL(fileURLWithPath: "/usr/bin/xip"), ["--expand", archive.path])
        case .aea:
            let key = try XcodeAEASigningKey.hexPublicKey(ofArchiveAt: archive)
            return (
                URL(fileURLWithPath: "/usr/bin/aa"),
                ["extract", "-i", archive.path, "-d", workspace.path, "-sign-pub-value", "hex:\(key)"]
            )
        }
    }

    func expansionFailure(reason: String) -> ScannerError {
        switch self {
        case .xip:
            .xipExtractionFailed(reason: reason)
        case .aea:
            .xcodeAEAExtractionFailed(reason: reason)
        }
    }
}
