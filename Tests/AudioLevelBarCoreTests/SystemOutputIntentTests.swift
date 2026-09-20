import XCTest
@testable import AudioLevelBarCore

final class SystemOutputIntentTests: XCTestCase {
    func testRequestsOutsideAWindowActAtOnce() {
        var intent = SystemOutputIntent()

        XCTAssertEqual(intent.handle(.rebuild(holding: false)), .start)
        XCTAssertNil(intent.pending)
        XCTAssertEqual(intent.handle(.stop(holding: false)), .stop)
        XCTAssertNil(intent.pending)
        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .none, "nothing is owed")
    }

    func testSystemOutputRebuildAskedDuringAHoldRunsOnceAfterRelease() {
        var intent = SystemOutputIntent()

        XCTAssertEqual(intent.handle(.rebuild(holding: true)), .none)
        XCTAssertEqual(intent.handle(.rebuild(holding: true)), .none)
        XCTAssertEqual(intent.handle(.rebuild(holding: true)), .none)
        XCTAssertEqual(intent.pending, .rebuild)

        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .start)
        XCTAssertNil(intent.pending)
        XCTAssertEqual(
            intent.handle(.release(startsHeld: false, rebuildDue: true)),
            .none,
            "the rebuild runs exactly once"
        )
    }

    func testInterruptedRebuildDoesNotOverwriteAPendingStop() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.stop(holding: true)), .none)

        XCTAssertEqual(intent.handle(.interrupted(monitoringEnabled: false)), .none)
        XCTAssertEqual(intent.pending, .stop)
        XCTAssertEqual(intent.handle(.interrupted(monitoringEnabled: true)), .none)
        XCTAssertEqual(intent.pending, .stop)

        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .stop)
    }

    func testInterruptedRebuildRunsAgainAfterTheWindow() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.rebuild(holding: false)), .start)

        XCTAssertEqual(intent.handle(.interrupted(monitoringEnabled: true)), .none)
        XCTAssertEqual(intent.pending, .rebuild)
        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .start)
    }

    func testInterruptedRebuildWithMonitoringOffOwesNothing() {
        var intent = SystemOutputIntent()

        XCTAssertEqual(intent.handle(.interrupted(monitoringEnabled: false)), .none)
        XCTAssertNil(intent.pending)
    }

    func testInterruptedStopIsIssuedAgainAfterTheWindow() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.stop(holding: false)), .stop)

        XCTAssertEqual(intent.handle(.stopInterrupted(monitoringEnabled: false)), .none)
        XCTAssertEqual(intent.pending, .stop)
        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .stop)
    }

    func testInterruptedStopWithMonitoringOnAgainOwesNothing() {
        var intent = SystemOutputIntent()

        XCTAssertEqual(intent.handle(.stopInterrupted(monitoringEnabled: true)), .none)
        XCTAssertNil(intent.pending, "the rebuild that turned monitoring on releases what the stop left")
    }

    func testLaterRequestDuringAHoldReplacesAnEarlierOne() {
        var intent = SystemOutputIntent()

        XCTAssertEqual(intent.handle(.stop(holding: true)), .none)
        XCTAssertEqual(intent.handle(.rebuild(holding: true)), .none)
        XCTAssertEqual(intent.pending, .rebuild)

        XCTAssertEqual(intent.handle(.stop(holding: true)), .none)
        XCTAssertEqual(intent.pending, .stop)
        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .stop)
    }

    func testStopsOnlyReleaseLeavesTheMeterRunningAndKeepsTheRebuildOwed() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.rebuild(holding: true)), .none)

        XCTAssertEqual(
            intent.handle(.release(startsHeld: true, rebuildDue: true)),
            .none,
            "no tap is destroyed right after the default output moved; the rebuild releases it"
        )
        XCTAssertEqual(intent.pending, .rebuild, "the rebuild waits for starts")
        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .start)
        XCTAssertNil(intent.pending)
    }

    func testRebuildAskedForWhileStartsAreHeldIsOwed() {
        var intent = SystemOutputIntent()

        XCTAssertEqual(intent.handle(.rebuild(holding: true)), .none)
        XCTAssertEqual(intent.pending, .rebuild)
    }

    func testStopsOnlyReleaseCarriesOutAPendingStop() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.stop(holding: true)), .none)

        XCTAssertEqual(intent.handle(.release(startsHeld: true, rebuildDue: true)), .stop)
        XCTAssertNil(intent.pending)
        XCTAssertEqual(intent.handle(.release(startsHeld: true, rebuildDue: true)), .none)
    }

    func testStopInterruptedWithMonitoringOnKeepsTheRebuildOwed() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.rebuild(holding: true)), .none)
        XCTAssertEqual(intent.handle(.release(startsHeld: true, rebuildDue: true)), .none)

        XCTAssertEqual(intent.handle(.stopInterrupted(monitoringEnabled: true)), .none)
        XCTAssertEqual(intent.pending, .rebuild)
        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .start)
    }

    func testInvalidationOwesOneRebuildAndKeepsAPendingStop() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.invalidated(monitoringEnabled: true)), .none)
        XCTAssertEqual(intent.handle(.invalidated(monitoringEnabled: true)), .none)
        XCTAssertEqual(intent.pending, .rebuild)

        var stopping = SystemOutputIntent()
        XCTAssertEqual(stopping.handle(.stop(holding: true)), .none)
        XCTAssertEqual(stopping.handle(.invalidated(monitoringEnabled: true)), .none)
        XCTAssertEqual(stopping.pending, .stop)

        var off = SystemOutputIntent()
        XCTAssertEqual(off.handle(.invalidated(monitoringEnabled: false)), .none)
        XCTAssertNil(off.pending)
    }

    func testARebuildNotYetDueIsNeitherIssuedNorStopped() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.invalidated(monitoringEnabled: true)), .none)

        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: false)), .none)
        XCTAssertEqual(intent.pending, .rebuild)
        XCTAssertEqual(
            intent.handle(.release(startsHeld: true, rebuildDue: false)),
            .none,
            "a stops-only release stops nothing that is owed a rebuild"
        )
        XCTAssertEqual(intent.pending, .rebuild)
        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: true)), .start)
    }

    func testAPendingStopIsNotHeldBackByTheRebuildSpacing() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.stop(holding: true)), .none)

        XCTAssertEqual(intent.handle(.release(startsHeld: false, rebuildDue: false)), .stop)
    }

    func testAUserRebuildIsNotHeldBackByTheRebuildSpacing() {
        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.invalidated(monitoringEnabled: true)), .none)

        XCTAssertEqual(intent.handle(.rebuild(holding: false)), .start, "Retry acts outside the window")
        XCTAssertNil(intent.pending)
    }
}
