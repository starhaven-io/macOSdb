import Foundation
import Testing

@testable import macOSdbCore

@Suite("Concurrent map tests")
struct ConcurrentMapTests {

    @Test("Collects every non-nil transformed value and drops nils")
    func collectsNonNil() async {
        let output = await mapConcurrent(Array(1...10), maxConcurrent: 3) { number in
            number.isMultiple(of: 2) ? number * 10 : nil
        }
        #expect(Set(output) == Set([20, 40, 60, 80, 100]))
    }

    @Test("Returns empty for empty input")
    func emptyInput() async {
        let output: [Int] = await mapConcurrent([], maxConcurrent: 4) { $0 }
        #expect(output.isEmpty)
    }

    @Test("Never runs more than maxConcurrent operations at once")
    func respectsConcurrencyLimit() async {
        let tracker = ConcurrencyTracker()
        _ = await mapConcurrent(Array(1...32), maxConcurrent: 4) { number in
            await tracker.enter()
            await Task.yield() // encourage overlap so the peak is actually exercised
            await tracker.leave()
            return number
        }
        #expect(await tracker.peak <= 4)
        #expect(await tracker.peak >= 1)
    }
}

private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}
