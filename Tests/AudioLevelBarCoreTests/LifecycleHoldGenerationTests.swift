import XCTest
@testable import AudioLevelBarCore

final class LifecycleHoldGenerationTests: XCTestCase {
    func testTokenStaysCurrentUntilTheWindowArms() {
        let generation = LifecycleHoldGeneration()
        let token = generation.current

        XCTAssertTrue(generation.isCurrent(token))
        XCTAssertTrue(generation.isCurrent(token), "reading does not advance")

        generation.advance()
        XCTAssertFalse(generation.isCurrent(token))
        XCTAssertTrue(generation.isCurrent(generation.current))
    }

    func testEveryReArmInvalidatesEveryEarlierToken() {
        let generation = LifecycleHoldGeneration()
        var tokens: [UInt64] = []
        for _ in 0..<3 {
            tokens.append(generation.current)
            generation.advance()
        }

        XCTAssertEqual(Set(tokens).count, 3)
        XCTAssertFalse(tokens.contains(where: generation.isCurrent))
    }

    func testAdvanceFromAnotherThreadInvalidatesATokenTakenBefore() {
        let generation = LifecycleHoldGeneration()
        // A start on a lifecycle queue took its token.
        let token = generation.current

        // A HAL listener advances the generation on its own queue.
        DispatchQueue(label: "listener").sync {
            generation.advance()
        }

        // The start's next check, on yet another queue, sees it at once.
        var stillCurrent = true
        let checked = DispatchSemaphore(value: 0)
        DispatchQueue(label: "lifecycle").async {
            stillCurrent = generation.isCurrent(token)
            checked.signal()
        }
        XCTAssertEqual(checked.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(stillCurrent)
        XCTAssertFalse(generation.isCurrent(token))
    }

    func testConcurrentAdvancesAreAllCounted() {
        let generation = LifecycleHoldGeneration()
        let start = generation.current

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            generation.advance()
        }

        XCTAssertEqual(generation.current, start + 1_000)
    }
}
