import XCTest
@testable import AudioLevelBarCore

final class HALPollWatchTests: XCTestCase {
    func testAPollInFlightDropsTheNextAndIsNotedSlowOnceAfterHalfASecond() {
        var watch = HALPollWatch()
        XCTAssertEqual(watch.issue(at: 10), .issued)
        XCTAssertTrue(watch.isInFlight)
        XCTAssertEqual(watch.issue(at: 10.25), .dropped)
        XCTAssertEqual(watch.issue(at: 10.5), .dropped)
        guard case let .droppedWhileSlow(issuedAgo) = watch.issue(at: 10.75) else {
            return XCTFail("a tick dropped 0.75 s after the issue notes the poll slow")
        }
        XCTAssertEqual(issuedAgo, 0.75, accuracy: 1e-9)
        XCTAssertEqual(watch.issue(at: 11), .dropped, "noted once per poll")
        XCTAssertEqual(watch.issue(at: 30), .dropped)
    }

    func testAReturnedPollThatWasNotedSlowReportsItsElapsedTime() {
        var watch = HALPollWatch()
        _ = watch.issue(at: 10)
        _ = watch.issue(at: 10.75)
        XCTAssertEqual(watch.returned(at: 12) ?? -1, 2, accuracy: 1e-9)
        XCTAssertFalse(watch.isInFlight)
        XCTAssertEqual(watch.issue(at: 12.25), .issued)
        XCTAssertNil(watch.returned(at: 12.3))
    }

    func testAPollThatTookLongWithoutADroppedTickStillReportsOnReturn() {
        var watch = HALPollWatch()
        _ = watch.issue(at: 10)
        XCTAssertEqual(watch.returned(at: 10.8) ?? -1, 0.8, accuracy: 1e-9)
    }

    func testAFastPollReportsNothingAndTheNextSlowPollIsNotedAgain() {
        var watch = HALPollWatch()
        _ = watch.issue(at: 10)
        _ = watch.issue(at: 10.75)
        _ = watch.returned(at: 11)
        _ = watch.issue(at: 11)
        XCTAssertNil(watch.returned(at: 11.1))
        _ = watch.issue(at: 12)
        XCTAssertEqual(watch.issue(at: 12.6), .droppedWhileSlow(issuedAgo: 12.6 - 12))
    }

    func testAReturnWithNoPollInFlightReportsNothing() {
        var watch = HALPollWatch()
        XCTAssertNil(watch.returned(at: 5))
    }

    func testADroppedPollThatAskedForTheDeviceListsIsOwedUntilOneCarriesThem() {
        var watch = HALPollWatch()
        _ = watch.issue(at: 10)
        XCTAssertEqual(watch.issue(at: 10.1), .dropped)
        XCTAssertFalse(watch.deviceListsOwed, "an ordinary tick owes nothing")

        XCTAssertEqual(watch.issue(at: 10.2, wantsDeviceLists: true), .dropped)
        XCTAssertTrue(watch.deviceListsOwed)
        _ = watch.returned(at: 10.3)

        XCTAssertTrue(watch.takeOwedDeviceLists())
        XCTAssertFalse(watch.takeOwedDeviceLists(), "taken once")
    }

    func testAPollIssuedWithTheDeviceListsPaysWhatIsOwed() {
        var watch = HALPollWatch()
        _ = watch.issue(at: 10)
        _ = watch.issue(at: 10.1, wantsDeviceLists: true)
        _ = watch.returned(at: 10.2)

        XCTAssertEqual(watch.issue(at: 10.25, wantsDeviceLists: true), .issued)
        XCTAssertFalse(watch.deviceListsOwed)
    }
}
