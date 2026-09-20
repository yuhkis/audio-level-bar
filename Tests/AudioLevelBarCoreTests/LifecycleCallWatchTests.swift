import XCTest
@testable import AudioLevelBarCore

final class LifecycleCallWatchTests: XCTestCase {
    func testNothingIssuedNeverStalls() {
        var watch = LifecycleCallWatch()
        XCTAssertFalse(watch.isOutstanding)
        XCTAssertFalse(watch.isStalled(now: 10_000))
        XCTAssertFalse(watch.noteStall(now: 10_000))
    }

    func testAStopThatNeverReportsBackStallsAfterTheTimeout() {
        var watch = LifecycleCallWatch()
        watch.issue(now: 100)

        XCTAssertTrue(watch.isOutstanding)
        XCTAssertFalse(watch.isStalled(now: 100 + LifecycleCallWatch.timeout - 0.1))
        XCTAssertTrue(watch.isStalled(now: 100 + LifecycleCallWatch.timeout))
        XCTAssertTrue(watch.isStalled(now: 10_000), "it stays stalled until it reports")
    }

    func testTheTimeoutIsTheMeterStartTimeout() {
        XCTAssertEqual(LifecycleCallWatch.timeout, 10)
    }

    func testReportClearsTheStall() {
        var watch = LifecycleCallWatch()
        let token = watch.issue(now: 100)
        XCTAssertTrue(watch.noteStall(now: 110))

        watch.report(token: token)
        XCTAssertFalse(watch.isOutstanding)
        XCTAssertFalse(watch.isStalled(now: 1_000))
        XCTAssertFalse(watch.stallNoted)
    }

    func testATokenlessReportClearsTheLatestCall() {
        var watch = LifecycleCallWatch()
        watch.issue(now: 100)
        watch.report()
        XCTAssertFalse(watch.isStalled(now: 1_000))
    }

    func testReissueRestartsTheTimeout() {
        var watch = LifecycleCallWatch()
        watch.issue(now: 100)
        watch.issue(now: 105)

        XCTAssertFalse(watch.isStalled(now: 114.9))
        XCTAssertTrue(watch.isStalled(now: 115))
    }

    func testAnEarlierCallsReportDoesNotClearALaterCall() {
        var watch = LifecycleCallWatch()
        let first = watch.issue(now: 100)
        let second = watch.issue(now: 101)

        watch.report(token: first)
        XCTAssertTrue(watch.isOutstanding, "the later call may still be waiting behind the earlier one")
        XCTAssertTrue(watch.isStalled(now: 111))

        watch.report(token: second)
        XCTAssertFalse(watch.isOutstanding)
    }

    func testAStallIsNotedOnce() {
        var watch = LifecycleCallWatch()
        watch.issue(now: 100)

        XCTAssertFalse(watch.noteStall(now: 105))
        XCTAssertTrue(watch.noteStall(now: 110))
        XCTAssertFalse(watch.noteStall(now: 111))
        XCTAssertTrue(watch.isStalled(now: 111))

        watch.issue(now: 200)
        XCTAssertTrue(watch.noteStall(now: 210), "a new call that stalls is noted again")
    }
}
