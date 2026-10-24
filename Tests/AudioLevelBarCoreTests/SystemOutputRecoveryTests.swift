import XCTest
@testable import AudioLevelBarCore

final class SystemOutputRecoveryTests: XCTestCase {
    func testInvalidationRequestsOneSpacedRebuild() {
        var recovery = SystemOutputRecovery()
        var intent = SystemOutputIntent()
        recovery.started(at: 10)

        recovery.invalidated(at: 20)
        XCTAssertEqual(intent.handle(.invalidated(monitoringEnabled: true)), .none)
        XCTAssertEqual(intent.pending, .rebuild)
        XCTAssertEqual(recovery.rebuildNotBefore, 22)
        XCTAssertFalse(recovery.isWatching, "an invalidated meter's silence is not checked again")
        XCTAssertEqual(recovery.check(at: 30), .none)

        // The window has released, but the spacing has not passed.
        XCTAssertEqual(
            intent.handle(.release(startsHeld: false, rebuildDue: recovery.rebuildIsDue(at: 21))),
            .none
        )
        XCTAssertEqual(intent.pending, .rebuild, "the rebuild stays owed")

        XCTAssertEqual(
            intent.handle(.release(startsHeld: false, rebuildDue: recovery.rebuildIsDue(at: 22))),
            .start
        )
        XCTAssertNil(intent.pending)
        XCTAssertEqual(
            intent.handle(.release(startsHeld: false, rebuildDue: recovery.rebuildIsDue(at: 23))),
            .none,
            "the rebuild runs exactly once"
        )
    }

    func testRepeatedInvalidationsBackOff() {
        var recovery = SystemOutputRecovery()
        var delays: [Double] = []
        var now: TimeInterval = 0
        for _ in 0..<4 {
            recovery.started(at: now)
            now += 1
            recovery.invalidated(at: now)
            delays.append((recovery.rebuildNotBefore ?? now) - now)
            now = recovery.rebuildNotBefore ?? now
        }

        XCTAssertEqual(delays, [2, 4, 8, 8])
        XCTAssertEqual(recovery.consecutiveInvalidations, 4)
    }

    func testARunLongerThanTheStableDurationStartsTheBackoffOver() {
        var recovery = SystemOutputRecovery()
        recovery.started(at: 0)
        recovery.invalidated(at: 1)
        recovery.started(at: 3)
        recovery.invalidated(at: 4)
        XCTAssertEqual(recovery.rebuildNotBefore, 8)

        recovery.started(at: 8)
        recovery.invalidated(at: 8 + SystemOutputRecovery.stableRunDuration)
        XCTAssertEqual(recovery.consecutiveInvalidations, 1)
        XCTAssertEqual(recovery.rebuildNotBefore, 8 + SystemOutputRecovery.stableRunDuration + 2)
    }

    func testNoCallbacksForFourSecondsRequestsRebuild() {
        var recovery = SystemOutputRecovery()
        recovery.started(at: 100)
        recovery.level(at: 100.25)

        XCTAssertEqual(recovery.check(at: 101), .none)
        XCTAssertEqual(recovery.check(at: 102.25), .showStale, "levels reset and the meter shows starting")
        XCTAssertEqual(recovery.check(at: 103), .none, "shown once per silence")
        XCTAssertEqual(recovery.check(at: 104.25), .rebuild)

        recovery.invalidated(at: 104.25)
        XCTAssertEqual(recovery.check(at: 110), .none, "one rebuild is asked for, not one per evaluation")
        XCTAssertEqual(recovery.rebuildNotBefore, 106.25)
    }

    func testAStartThatNeverDeliversALevelRequestsRebuild() {
        var recovery = SystemOutputRecovery()
        recovery.started(at: 0)

        XCTAssertEqual(recovery.check(at: 2), .showStale)
        XCTAssertEqual(recovery.check(at: 4), .rebuild)
    }

    func testSilentBuffersAreNotStale() {
        // A silent buffer arrives as a level of -inf dB. Its value never
        // reaches the recovery: arriving is what counts.
        var recovery = SystemOutputRecovery()
        recovery.started(at: 0)
        var now: TimeInterval = 0
        while now < 60 {
            now += 0.25
            recovery.level(at: now)
            XCTAssertEqual(recovery.check(at: now), .none)
        }
    }

    func testALevelAfterAStaleDisplayWatchesTheNextSilenceAgain() {
        var recovery = SystemOutputRecovery()
        recovery.started(at: 0)
        XCTAssertEqual(recovery.check(at: 2), .showStale)
        recovery.level(at: 3)

        XCTAssertEqual(recovery.check(at: 4), .none)
        XCTAssertEqual(recovery.check(at: 5), .showStale)
    }

    func testAStoppedMeterIsNotWatchedAndKeepsItsSpacing() {
        var recovery = SystemOutputRecovery()
        recovery.started(at: 0)
        recovery.invalidated(at: 1)
        recovery.stopped()

        XCTAssertEqual(recovery.rebuildNotBefore, 3, "a stop does not bring the rebuild forward")
        XCTAssertFalse(recovery.rebuildIsDue(at: 2))
        XCTAssertTrue(recovery.rebuildIsDue(at: 3))
        XCTAssertEqual(recovery.check(at: 100), .none)
        XCTAssertEqual(recovery.consecutiveInvalidations, 1, "the backoff count stays")

        recovery.level(at: 101)
        XCTAssertFalse(recovery.isWatching, "a level without a start does not start watching")

        recovery.rebuildIssued()
        XCTAssertNil(recovery.rebuildNotBefore, "an issued rebuild has spent its spacing")
        XCTAssertTrue(recovery.rebuildIsDue(at: 0))
    }

    func testTheBackoffSurvivesBuildsThatAreAbandonedBeforeTheyStart() {
        // A listener that fires on the meter's own build invalidates it and
        // abandons that build, which reports interrupted: no start in between.
        var recovery = SystemOutputRecovery()
        recovery.started(at: 0)

        recovery.invalidated(at: 1)
        recovery.stopped()
        XCTAssertFalse(recovery.rebuildIsDue(at: 2.9))
        XCTAssertTrue(recovery.rebuildIsDue(at: 3))
        recovery.rebuildIssued()

        recovery.invalidated(at: 4)
        recovery.stopped()
        XCTAssertFalse(recovery.rebuildIsDue(at: 7.9))
        XCTAssertTrue(recovery.rebuildIsDue(at: 8))
        recovery.rebuildIssued()

        recovery.invalidated(at: 9)
        recovery.stopped()
        XCTAssertFalse(recovery.rebuildIsDue(at: 16.9))
        XCTAssertTrue(recovery.rebuildIsDue(at: 17))
    }

    func testAnInvalidationDuringABuildIsNotReleasedBeforeItsSpacing() {
        var recovery = SystemOutputRecovery()
        var intent = SystemOutputIntent()
        recovery.started(at: 0)
        XCTAssertEqual(intent.handle(.rebuild(holding: false)), .start)
        recovery.rebuildIssued()

        // The build's listener fires; the build is abandoned and reports so.
        recovery.invalidated(at: 1)
        XCTAssertEqual(intent.handle(.invalidated(monitoringEnabled: true)), .none)
        recovery.stopped()
        XCTAssertEqual(intent.handle(.interrupted(monitoringEnabled: true)), .none)

        XCTAssertEqual(
            intent.handle(.release(startsHeld: false, rebuildDue: recovery.rebuildIsDue(at: 2))),
            .none,
            "the window released, but the spacing has not passed"
        )
        XCTAssertEqual(
            intent.handle(.release(startsHeld: false, rebuildDue: recovery.rebuildIsDue(at: 3))),
            .start
        )
    }

    /// Invalidates a meter that started a second earlier, `count` times in a
    /// row, each at the earliest time its rebuild was due.
    private func invalidateInARow(_ recovery: inout SystemOutputRecovery, count: Int, from start: TimeInterval = 0) -> TimeInterval {
        var now = start
        for _ in 0..<count {
            recovery.started(at: now)
            now += 1
            recovery.invalidated(at: now)
            now = recovery.rebuildNotBefore ?? now
        }
        return now
    }

    func testRebuildsGiveUpAtTheMaximumInvalidationsInARow() {
        var recovery = SystemOutputRecovery()
        let maximum = SystemOutputRecovery.maximumConsecutiveInvalidations
        let now = invalidateInARow(&recovery, count: maximum - 1)
        XCTAssertFalse(recovery.rebuildsExhausted)
        XCTAssertTrue(recovery.rebuildIsDue(at: now), "every invalidation before the maximum is rebuilt")

        recovery.started(at: now)
        recovery.invalidated(at: now + 1)
        XCTAssertTrue(recovery.rebuildsExhausted)
        XCTAssertNil(recovery.rebuildNotBefore)
        XCTAssertFalse(recovery.rebuildIsDue(at: now + 1))
        XCTAssertFalse(recovery.rebuildIsDue(at: now + 3_600), "however long it waits")
        XCTAssertEqual(recovery.check(at: now + 3_600), .none, "nothing is watched either")

        var intent = SystemOutputIntent()
        XCTAssertEqual(intent.handle(.invalidated(monitoringEnabled: true)), .none)
        XCTAssertEqual(
            intent.handle(.release(startsHeld: false, rebuildDue: recovery.rebuildIsDue(at: now + 3_600))),
            .none,
            "the rebuild stays owed and is never issued"
        )
        XCTAssertEqual(intent.pending, .rebuild)
    }

    func testAStableRunKeepsTheRebuildsFromGivingUp() {
        var recovery = SystemOutputRecovery()
        let maximum = SystemOutputRecovery.maximumConsecutiveInvalidations
        var now = invalidateInARow(&recovery, count: maximum - 1)
        recovery.started(at: now)
        now += SystemOutputRecovery.stableRunDuration
        recovery.invalidated(at: now)

        XCTAssertFalse(recovery.rebuildsExhausted)
        XCTAssertEqual(recovery.consecutiveInvalidations, 1)
        XCTAssertEqual(recovery.rebuildNotBefore, now + 2)
    }

    func testStartingOverRebuildsAgainFromTheShortestSpacing() {
        var recovery = SystemOutputRecovery()
        let now = invalidateInARow(&recovery, count: SystemOutputRecovery.maximumConsecutiveInvalidations)
        XCTAssertTrue(recovery.rebuildsExhausted)

        recovery.startOver()
        XCTAssertFalse(recovery.rebuildsExhausted)
        XCTAssertTrue(recovery.rebuildIsDue(at: now), "the rebuild owed is due again")

        recovery.rebuildIssued()
        recovery.started(at: now)
        recovery.invalidated(at: now + 1)
        XCTAssertEqual(recovery.consecutiveInvalidations, 1)
        XCTAssertEqual(recovery.rebuildNotBefore, now + 3)
    }

    func testAServiceRestartKeepsRebuildsThatGaveUpAndOtherwiseForgetsTheCount() {
        var exhausted = SystemOutputRecovery()
        _ = invalidateInARow(&exhausted, count: SystemOutputRecovery.maximumConsecutiveInvalidations)
        exhausted.serviceRestarted()
        XCTAssertTrue(exhausted.rebuildsExhausted, "a restart is neither a retry nor another output")
        XCTAssertFalse(exhausted.isWatching)

        var counting = SystemOutputRecovery()
        _ = invalidateInARow(&counting, count: 3)
        counting.serviceRestarted()
        XCTAssertEqual(counting, SystemOutputRecovery())
    }

    func testResetForgetsTheBackoff() {
        var recovery = SystemOutputRecovery()
        recovery.started(at: 0)
        recovery.invalidated(at: 1)
        recovery.reset()

        XCTAssertEqual(recovery, SystemOutputRecovery())
    }

    func testSleepNeitherChecksSilenceNorCountsInvalidationsNorDueARebuild() {
        var recovery = SystemOutputRecovery()
        recovery.started(at: 0)
        recovery.invalidated(at: 1)
        XCTAssertEqual(recovery.consecutiveInvalidations, 1)

        recovery.willSleep()
        XCTAssertTrue(recovery.isAsleep)
        XCTAssertFalse(recovery.isWatching)
        XCTAssertFalse(recovery.rebuildIsDue(at: 100), "nothing is rebuilt while asleep")

        // A rebuild issued before the sleep reports it started, its levels
        // never arrive, and listeners keep invalidating it.
        var now: TimeInterval = 10
        for _ in 0..<(SystemOutputRecovery.maximumConsecutiveInvalidations * 2) {
            recovery.started(at: now)
            now += SystemOutputRecovery.rebuildAfterSilence + 8
            XCTAssertEqual(recovery.check(at: now), .none, "a sleeping output's silence is not stale")
            recovery.invalidated(at: now)
        }
        XCTAssertEqual(recovery.consecutiveInvalidations, 1, "not counted across the sleep")
        XCTAssertFalse(recovery.rebuildsExhausted)
        XCTAssertFalse(recovery.rebuildIsDue(at: now))

        recovery.reset()
        recovery.serviceRestarted()
        XCTAssertTrue(recovery.isAsleep, "turning monitoring off or a restart does not end the sleep")
    }

    func testTheWakeStartsTheCountOverAndDuesOneRebuildAtOnce() {
        var recovery = SystemOutputRecovery()
        let now = invalidateInARow(&recovery, count: SystemOutputRecovery.maximumConsecutiveInvalidations)
        XCTAssertTrue(recovery.rebuildsExhausted)
        recovery.willSleep()

        recovery.didWake()

        XCTAssertFalse(recovery.isAsleep)
        XCTAssertEqual(recovery.consecutiveInvalidations, 0)
        XCTAssertNil(recovery.rebuildNotBefore)
        XCTAssertTrue(recovery.rebuildIsDue(at: now), "due with no spacing, once the window releases")
        XCTAssertFalse(recovery.isWatching, "levels are watched again once the rebuild starts")

        recovery.rebuildIssued()
        recovery.started(at: now + 1)
        XCTAssertEqual(recovery.check(at: now + 1 + SystemOutputRecovery.rebuildAfterSilence), .rebuild)
    }
}
