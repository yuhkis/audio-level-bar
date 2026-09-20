import XCTest
@testable import AudioLevelBarCore

/// A sleep as the owner presents it: the lifecycle clock does not count time
/// asleep, so the wake arrives as an ordinary short pause.
///
/// These tests record the intent. Core only receives the times it is given;
/// the owner's single lifecycle clock is what keeps a sleep out of them.
final class SleepGapTests: XCTestCase {
    func testSleepGapIsAnOrdinaryPauseForTheWindow() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)

        // Asleep; the clock does not advance. The wake evaluates half a
        // second later on that clock, still inside the settle period.
        XCTAssertTrue(window.isHolding(at: 100.5))
        XCTAssertFalse(window.takeRelease(at: 100.5))

        // A Bluetooth device arrives shortly after the wake and extends the
        // window instead of being acted on.
        window.noteChange(at: 102)
        XCTAssertEqual(window.releaseTime, 105)
        XCTAssertTrue(window.isHolding(at: 104.9))
        XCTAssertFalse(window.takeRelease(at: 104.9))

        XCTAssertTrue(window.takeRelease(at: 105))
        XCTAssertFalse(window.takeRelease(at: 106), "the window releases once")
        XCTAssertFalse(window.isArmed)
    }

    func testStartIssuedBeforeASleepIsNotStalledAfterIt() {
        var session = MeterSession()
        XCTAssertEqual(
            session.handle(.evaluate(target: .device(41), holding: false, startsHeld: false, now: 100)),
            .start(41)
        )

        // The wake evaluates one second later on the lifecycle clock.
        XCTAssertNil(session.handle(.evaluate(target: .device(41), holding: false, startsHeld: false, now: 101)))
        XCTAssertEqual(session.phase, .starting(41))
        XCTAssertFalse(session.isStalled)

        XCTAssertNil(session.handle(.started(41, now: 100)))
        XCTAssertEqual(session.phase, .running(41))
    }
}
