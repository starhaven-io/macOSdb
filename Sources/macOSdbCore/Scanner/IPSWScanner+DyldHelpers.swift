import Foundation

func findDyldCache(mountPoint: String) -> URL? {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: mountPoint)

    func isConfinedCacheFile(_ url: URL) -> Bool {
        guard let fileHandle = try? ScannerFileReader.fileHandle(at: url, confinedTo: root) else {
            return false
        }
        try? fileHandle.close()
        return true
    }

    let candidates = [
        "System/Library/dyld/dyld_shared_cache_arm64e",
        "System/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e",
        "System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
    ]

    for candidate in candidates {
        let path = root.appendingPathComponent(candidate)
        if isConfinedCacheFile(path) {
            return path
        }
    }

    let searchPaths = [
        root.appendingPathComponent("System/Library/dyld"),
        root.appendingPathComponent("System/Cryptexes/OS/System/Library/dyld")
    ]

    for searchPath in searchPaths {
        guard let confinedSearchPath = try? ScannerFileReader.resolvedDirectory(
            at: searchPath,
            confinedTo: root
        ), let contents = try? fileManager.contentsOfDirectory(
            at: confinedSearchPath,
            includingPropertiesForKeys: nil
        ) else { continue }

        let cache = contents
            .filter {
                $0.lastPathComponent.hasPrefix("dyld_shared_cache")
                    && !$0.lastPathComponent.hasSuffix(".map")
                    && !$0.lastPathComponent.hasSuffix(".symbols")
                    && isConfinedCacheFile($0)
            }
            .min { $0.lastPathComponent < $1.lastPathComponent }
        if let cache { return cache }
    }

    return nil
}

/// Falls back to prefix matching when the soversion differs.
func resolveDylibPath(
    _ expectedPath: String,
    in dylibSet: Set<String>,
    allPaths: [String]
) -> String? {
    if dylibSet.contains(expectedPath) {
        return expectedPath
    }

    let url = URL(fileURLWithPath: expectedPath)
    let filename = url.lastPathComponent
    let dir = url.deletingLastPathComponent().path

    guard let dotIndex = filename.firstIndex(of: ".") else {
        return nil
    }

    let baseName = String(filename[..<dotIndex])
    let prefix = dir + "/" + baseName + "."

    return allPaths.first { $0.hasPrefix(prefix) && $0.hasSuffix(".dylib") }
}

/// Merges cryptex components over system ones, with cryptex winning on name collisions.
func merging(_ system: [Component], overriddenBy cryptex: [Component]) -> [Component] {
    guard !cryptex.isEmpty else { return system }
    let cryptexNames = Set(cryptex.map(\.name))
    return system.filter { !cryptexNames.contains($0.name) } + cryptex
}
