import Foundation

public enum ScannerError: LocalizedError {
    case ipswNotFound(path: String)
    case ipswExtractionFailed(reason: String)
    case systemDMGNotFound
    case dmgMountFailed(path: String, reason: String)
    case noKernelcachesFound
    case dyldCacheParseFailed(reason: String)
    case componentExtractionFailed(name: String, reason: String)
    case metadataExtractionFailed(reason: String)
    case aeaDecryptionFailed(reason: String)
    case archiveNotFound(path: String)
    case xipExtractionFailed(reason: String)
    case xcodeAppNotFound(reason: String)
    case versionPlistNotFound(reason: String)

    public var errorDescription: String? {
        switch self {
        case .ipswNotFound(let path):
            "IPSW file not found: \(path)"
        case .ipswExtractionFailed(let reason):
            "Failed to extract IPSW: \(reason)"
        case .systemDMGNotFound:
            "Could not find system DMG inside the IPSW"
        case .dmgMountFailed(let path, let reason):
            "Failed to mount DMG \(path): \(reason)"
        case .noKernelcachesFound:
            "No kernelcache files found in the IPSW"
        case .dyldCacheParseFailed(let reason):
            "Failed to parse dyld shared cache: \(reason)"
        case .componentExtractionFailed(let name, let reason):
            "Failed to extract \(name): \(reason)"
        case .metadataExtractionFailed(let reason):
            "Failed to extract IPSW metadata: \(reason)"
        case .aeaDecryptionFailed(let reason):
            "AEA decryption failed: \(reason)"
        case .archiveNotFound(let path):
            "Archive not found: \(path)"
        case .xipExtractionFailed(let reason):
            "Failed to extract XIP archive: \(reason)"
        case .xcodeAppNotFound(let reason):
            "Xcode.app not found in extracted archive: \(reason)"
        case .versionPlistNotFound(let reason):
            "Version plist not found: \(reason)"
        }
    }
}
