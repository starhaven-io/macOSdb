import Foundation

extension IPSWScanner {
    func logDyldCacheDiagnostics(
        cachePath: URL
    ) -> (allDylibs: [String], dylibSet: Set<String>) {
        sendVerbose("Found dyld cache: \(cachePath.lastPathComponent)")

        let basePath = cachePath.path
        var subcacheCount = 0
        for idx in 1...99 {
            guard !Task.isCancelled else { break }
            let unpadded = basePath + ".\(idx)"
            let padded = basePath + String(format: ".%02d", idx)
            if FileManager.default.fileExists(atPath: unpadded)
                || FileManager.default.fileExists(atPath: padded) {
                subcacheCount += 1
            } else {
                break
            }
        }
        sendVerbose("Subcache files: \(subcacheCount)")

        let allDylibs = DyldCacheExtractor.listDylibs(cachePath: cachePath)
        let dylibSet = Set(allDylibs)
        sendVerbose("Image table contains \(allDylibs.count) dylibs")
        if !allDylibs.isEmpty {
            let targetPaths = Set(dyldCacheComponents.map(\.path))
            for path in targetPaths.sorted() {
                let found = dylibSet.contains(path)
                sendVerbose("  \(path): \(found ? "found" : "NOT FOUND") in image table")
            }
        }

        return (allDylibs, dylibSet)
    }

    func sendProgress(_ progress: ScanProgress) {
        onProgress?(progress)
    }

    func sendVerbose(_ message: String) {
        onVerbose?(message)
    }
}
