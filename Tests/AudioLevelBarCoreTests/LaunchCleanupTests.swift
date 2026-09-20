import XCTest
@testable import AudioLevelBarCore

final class LaunchCleanupTests: XCTestCase {
    func testTheCleanupIsOwedUntilTheStaleRemovalHasRun() {
        var cleanup = LaunchCleanup()
        XCTAssertTrue(cleanup.isOwed)

        _ = cleanup.staleRemovalFinished(.completed)
        XCTAssertFalse(cleanup.isOwed)
    }

    func testACompletedStaleRemovalReclaimsEveryTapOnce() {
        var cleanup = LaunchCleanup()

        XCTAssertEqual(cleanup.staleRemovalFinished(.completed), .reclaim(.everyTapOfThisApp))
        XCTAssertEqual(cleanup.phase, .done)
        XCTAssertEqual(cleanup.staleRemovalFinished(.completed), .none, "it runs once")
        XCTAssertEqual(cleanup.publicationTeardownCompleted(), .none, "a later teardown reclaims nothing")
    }

    func testAStaleDeviceInUseOrNotRemovedDefersTheReclaimToACompletedTeardown() {
        for outcome in [LaunchCleanup.StaleRemoval.inUse, .failed] {
            var cleanup = LaunchCleanup()

            XCTAssertEqual(cleanup.staleRemovalFinished(outcome), .none, "no tap goes while the device may still exist")
            XCTAssertEqual(cleanup.phase, .reclaimOwed)
            XCTAssertFalse(cleanup.isOwed, "starts are no longer held for it")

            XCTAssertEqual(cleanup.publicationTeardownCompleted(), .reclaim(.publishedMicrophoneTaps))
            XCTAssertEqual(cleanup.phase, .done)
            XCTAssertEqual(cleanup.publicationTeardownCompleted(), .none)
        }
    }

    func testATeardownBeforeTheCleanupRanReclaimsNothing() {
        var cleanup = LaunchCleanup()

        XCTAssertEqual(cleanup.publicationTeardownCompleted(), .none)
        XCTAssertTrue(cleanup.isOwed, "the cleanup still runs at the first release that admits starts")
    }

    // MARK: A reclaim a quiet window held back

    func testAnInterruptedReclaimOfEveryTapOwesTheWholeCleanupAgain() {
        var cleanup = LaunchCleanup()
        XCTAssertEqual(cleanup.staleRemovalFinished(.completed), .reclaim(.everyTapOfThisApp))

        cleanup.reclaimInterrupted(.everyTapOfThisApp)

        XCTAssertTrue(cleanup.isOwed, "starts stay held until the cleanup has run")
        XCTAssertEqual(
            cleanup.staleRemovalFinished(.completed),
            .reclaim(.everyTapOfThisApp),
            "and the release after the window reclaims what is left"
        )
        XCTAssertEqual(cleanup.phase, .done)
    }

    func testAnInterruptedReclaimOfThePublishedMicrophonesTapsWaitsForACompletedTeardownAgain() {
        var cleanup = LaunchCleanup()
        XCTAssertEqual(cleanup.staleRemovalFinished(.inUse), .none)
        XCTAssertEqual(cleanup.publicationTeardownCompleted(), .reclaim(.publishedMicrophoneTaps))

        cleanup.reclaimInterrupted(.publishedMicrophoneTaps)

        XCTAssertEqual(cleanup.phase, .reclaimOwed)
        XCTAssertFalse(cleanup.isOwed, "starts are not held for it")
        XCTAssertEqual(cleanup.publicationTeardownCompleted(), .reclaim(.publishedMicrophoneTaps))
    }

    func testAnInterruptionReportedWhenNoReclaimWasIssuedChangesNothing() {
        var owed = LaunchCleanup()
        owed.reclaimInterrupted(.publishedMicrophoneTaps)
        XCTAssertEqual(owed.phase, .owed)

        var waiting = LaunchCleanup()
        _ = waiting.staleRemovalFinished(.failed)
        waiting.reclaimInterrupted(.everyTapOfThisApp)
        XCTAssertEqual(waiting.phase, .reclaimOwed, "only a reclaim that was issued can be owed again")
    }
}
