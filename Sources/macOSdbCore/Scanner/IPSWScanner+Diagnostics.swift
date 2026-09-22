import Foundation

extension IPSWScanner {
    func logFilesystemComponentFailure(
        _ name: String,
        reason: String,
        overriding systemComponents: [Component]?
    ) {
        guard let systemComponents else {
            sendVerbose("\(name): \(reason)")
            return
        }
        if systemComponents.contains(where: { $0.name == name }) {
            sendVerbose("\(name): no usable cryptex override (\(reason)); retaining system-image result")
        } else {
            sendVerbose("\(name): cryptex lookup failed (\(reason)); no system-image result available")
        }
    }

    func logDyldCacheDiagnostics(
        cachePath: URL,
        confinedTo root: URL
    ) -> (allDylibs: [String], dylibSet: Set<String>) {
        sendVerbose("Found dyld cache: \(cachePath.lastPathComponent)")

        let subcacheCount = DyldCacheExtractor.subcacheCount(cachePath: cachePath, confinedTo: root)
        guard !Task.isCancelled else { return ([], []) }
        if let subcacheCount {
            sendVerbose("Subcache entries: \(subcacheCount)")
        } else {
            sendVerbose("Subcache entries: unavailable (invalid or unreadable metadata)")
        }

        let allDylibs = DyldCacheExtractor.listDylibs(cachePath: cachePath, confinedTo: root)
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
