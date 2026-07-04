import Foundation

/// Maps `items` through `transform` with at most `maxConcurrent` operations in
/// flight at once, collecting the non-nil results. Used to bound memory when each
/// operation reads a whole untrusted file into memory (e.g. kernelcache parsing):
/// a large `items` count can't spawn an unbounded number of concurrent readers.
///
/// Result order is not significant — callers sort afterwards. `maxConcurrent` is
/// clamped to at least 1.
func mapConcurrent<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    maxConcurrent: Int,
    _ transform: @Sendable @escaping (Item) async -> Output?
) async -> [Output] {
    guard !items.isEmpty else { return [] }
    guard !Task.isCancelled else { return [] }
    let window = max(1, min(maxConcurrent, items.count))

    return await withTaskGroup(of: Output?.self, returning: [Output].self) { group in
        var results: [Output] = []
        var next = 0

        // Prime the window, then add one task each time a previous one finishes.
        while next < window, !Task.isCancelled {
            let item = items[next]
            group.addTask {
                guard !Task.isCancelled else { return nil }
                return await transform(item)
            }
            next += 1
        }
        while let value = await group.next() {
            if Task.isCancelled {
                group.cancelAll()
                break
            }
            if let value { results.append(value) }
            if next < items.count {
                let item = items[next]
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return await transform(item)
                }
                next += 1
            }
        }
        return results
    }
}
