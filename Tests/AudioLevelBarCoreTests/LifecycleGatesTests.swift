import XCTest
@testable import AudioLevelBarCore

/// What an evaluation may issue beyond the quiet window's own admission: the
/// generation its thread has armed the window for, a default-device write
/// outstanding after the window disarmed, and the launch cleanup.
final class LifecycleGatesTests: XCTestCase {
    private func admission(
        _ window: LifecycleQuietWindow,
        at now: TimeInterval,
        fresh: TimeInterval?,
        writes: Int
    ) -> LifecycleQuietWindow.Admission {
        window.admission(at: now, freshestSnapshotIssuedAt: fresh, outstandingDefaultWrites: writes)
    }

    func testAGenerationTheOwnerHasNotSeenHoldsWhateverTheWindowAdmits() {
        for windowAdmission in [LifecycleQuietWindow.Admission.full, .stopsOnly, .hold] {
            XCTAssertEqual(
                LifecycleQuietWindow.admission(windowAdmission, generationSeenByOwner: 4, currentGeneration: 5),
                .hold,
                "a listener advanced the generation before the owner armed the window"
            )
            XCTAssertEqual(
                LifecycleQuietWindow.admission(windowAdmission, generationSeenByOwner: 5, currentGeneration: 5),
                windowAdmission
            )
        }
    }

    func testAWindowDisarmedWithAWriteOutstandingAdmitsNoStarts() {
        var window = LifecycleQuietWindow()
        // A change at 100, one carried past the cap at 115.2, and a pick at
        // 131 whose write waits behind a poll issued at 130.3.
        window.noteChange(at: 100)
        window.noteChange(at: 115.2)
        window.noteChange(at: 131)
        XCTAssertTrue(window.hasCarriedChange)

        XCTAssertEqual(admission(window, at: 134.1, fresh: 130.3, writes: 1), .stopsOnly)
        XCTAssertTrue(window.takeRelease(at: 134.1))
        XCTAssertEqual(window.releaseTime, 115.2 + LifecycleQuietWindow.cap, "the carried window is armed")

        XCTAssertEqual(admission(window, at: 134.2, fresh: 130.3, writes: 1), .stopsOnly)
        XCTAssertTrue(window.takeRelease(at: 134.2))
        XCTAssertFalse(window.isArmed, "3 s after the pick, the release disarms")

        XCTAssertEqual(
            admission(window, at: 134.3, fresh: 130.3, writes: 1),
            .stopsOnly,
            "nothing starts just before the default moves"
        )
        XCTAssertEqual(admission(window, at: 134.3, fresh: 130.3, writes: 0), .full)
    }

    func testTheLaunchCleanupHoldsStartsUntilItHasRun() {
        var cleanup = LaunchCleanup()
        XCTAssertTrue(cleanup.holdsStarts(admission: .full), "the window released before the cleanup ran")
        XCTAssertTrue(cleanup.holdsStarts(admission: .stopsOnly))

        _ = cleanup.staleRemovalFinished(.inUse)
        XCTAssertFalse(cleanup.holdsStarts(admission: .full), "any outcome lets starts through")
        XCTAssertTrue(cleanup.holdsStarts(admission: .stopsOnly))
        XCTAssertTrue(cleanup.holdsStarts(admission: .hold))
    }
}
