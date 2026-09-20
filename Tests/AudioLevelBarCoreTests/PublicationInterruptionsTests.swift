import XCTest
@testable import AudioLevelBarCore

final class PublicationInterruptionsTests: XCTestCase {
    private let maximum = PublicationInterruptions.maximumConsecutiveInterruptions

    func testTheMaximumInterruptionInARowEndsThePublicationsOnce() {
        var interruptions = PublicationInterruptions()
        XCTAssertFalse(interruptions.isExhausted)
        XCTAssertEqual(maximum, 3)

        for _ in 1..<maximum {
            XCTAssertFalse(interruptions.interrupted())
            XCTAssertFalse(interruptions.isExhausted)
        }
        XCTAssertTrue(interruptions.interrupted(), "the maximum interruption in a row ends them")
        XCTAssertTrue(interruptions.isExhausted)
        XCTAssertEqual(interruptions.consecutiveInterruptions, maximum)

        XCTAssertFalse(interruptions.interrupted(), "they end once")
        XCTAssertTrue(interruptions.isExhausted)
    }

    func testACompletedPublicationStartsTheCountOver() {
        var interruptions = PublicationInterruptions()
        for _ in 1..<maximum {
            interruptions.interrupted()
        }

        interruptions.startOver()

        XCTAssertEqual(interruptions.consecutiveInterruptions, 0)
        for _ in 1..<maximum {
            XCTAssertFalse(interruptions.interrupted(), "only interruptions with no completed publication between count")
        }
        XCTAssertTrue(interruptions.interrupted())
    }

    func testStartingOverLiftsAnExhaustion() {
        var interruptions = PublicationInterruptions()
        for _ in 0..<maximum {
            interruptions.interrupted()
        }
        XCTAssertTrue(interruptions.isExhausted)

        interruptions.startOver()

        XCTAssertFalse(interruptions.isExhausted)
        XCTAssertEqual(interruptions, PublicationInterruptions())
    }
}
