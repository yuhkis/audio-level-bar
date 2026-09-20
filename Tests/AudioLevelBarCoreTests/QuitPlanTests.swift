import XCTest
@testable import AudioLevelBarCore

final class QuitPlanTests: XCTestCase {
    func testQuitStopsThePublisherBeforeWithdrawingThePublicationAndThenWaits() throws {
        let steps = QuitPlan.steps
        let engines = try XCTUnwrap(steps.firstIndex(of: .stopProcessingEngines))
        let publication = try XCTUnwrap(steps.firstIndex(of: .withdrawPublication))
        let microphone = try XCTUnwrap(steps.firstIndex(of: .stopMicrophoneMeter))
        let systemOutput = try XCTUnwrap(steps.firstIndex(of: .stopSystemOutputMeter))
        XCTAssertLessThan(publication, microphone, "the queued stops follow the withdrawal")
        XCTAssertLessThan(publication, systemOutput, "the queued stops follow the withdrawal")

        XCTAssertLessThan(engines, publication, "the publisher stops before its tap is withdrawn")
        XCTAssertEqual(steps.first, .closeLevelGates, "no IO thread processes anything while Quit tears down")
        XCTAssertEqual(steps.last, .waitForLifecycleStops(idleTimeout: 3, ceiling: 8))
        XCTAssertEqual(
            steps.filter { if case .waitForLifecycleStops = $0 { return true } else { return false } }.count,
            1
        )
        XCTAssertEqual(
            Set(steps.dropLast().map { "\($0)" }),
            Set([
                "closeLevelGates",
                "stopProcessingEngines",
                "withdrawPublication",
                "stopMicrophoneMeter",
                "stopSystemOutputMeter"
            ]),
            "every queued stop is issued before the wait"
        )
    }

    // MARK: Deferral

    func testNoDeferralWithoutAWindow() {
        XCTAssertNil(QuitPlan.windowEnd(now: 100, settleEnd: nil, outstandingDefaultWrites: 0, generationUnseen: false))
        XCTAssertEqual(QuitPlan.deferral(now: 100, windowEnd: nil, deadline: 103), 0)
    }

    func testDeferralEndsThreeSecondsAfterTheLastChange() {
        XCTAssertEqual(QuitPlan.deferral(now: 100, windowEnd: 101.5, deadline: 103), 1.5, accuracy: 1e-9)
    }

    func testDeferralNeverPassesTheDeadlineFixedAtTheRequest() {
        XCTAssertEqual(QuitPlan.deferralMaximum, 3)
        XCTAssertEqual(QuitPlan.deferral(now: 100, windowEnd: 110, deadline: 103), 3)
        XCTAssertEqual(
            QuitPlan.deferral(now: 102.5, windowEnd: 110, deadline: 103),
            0.5,
            accuracy: 1e-9,
            "a change noted during the deferral moves the end, and the deadline still bounds it"
        )
        XCTAssertEqual(QuitPlan.deferral(now: 103, windowEnd: 110, deadline: 103), 0)
    }

    func testAnOutstandingDefaultWriteDefersUntilTheDeadline() {
        let end = QuitPlan.windowEnd(now: 100, settleEnd: 101, outstandingDefaultWrites: 1, generationUnseen: false)
        XCTAssertEqual(end, .infinity)
        XCTAssertEqual(QuitPlan.deferral(now: 100, windowEnd: end, deadline: 103), 3)
    }

    func testAGenerationTheOwnerHasNotArmedForCountsAsAChangeNow() {
        XCTAssertEqual(QuitPlan.windowEnd(now: 100, settleEnd: nil, outstandingDefaultWrites: 0, generationUnseen: true), 103)
        XCTAssertEqual(QuitPlan.windowEnd(now: 100, settleEnd: 104, outstandingDefaultWrites: 0, generationUnseen: true), 104)
    }

    func testASettledWindowWaitingOnlyForAPollDefersNothing() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 90)
        XCTAssertEqual(window.admission(at: 100, freshestSnapshotIssuedAt: 92, outstandingDefaultWrites: 0), .hold)
        let end = QuitPlan.windowEnd(now: 100, settleEnd: window.settleEnd, outstandingDefaultWrites: 0, generationUnseen: false)
        XCTAssertEqual(QuitPlan.deferral(now: 100, windowEnd: end, deadline: 103), 0, "no change for 3 s")
    }

    func testAReleaseTheCapForcesWithinTheSettlePeriodDefersQuit() {
        var window = LifecycleQuietWindow()
        for time in stride(from: 0.0, through: 14.0, by: 2.0) {
            window.noteChange(at: time)
        }
        let now = 15.2
        XCTAssertEqual(window.admission(at: now, freshestSnapshotIssuedAt: 15.1, outstandingDefaultWrites: 0), .stopsOnly)
        XCTAssertEqual(window.releaseTime, 15, "the cap brought the release forward")
        XCTAssertEqual(window.settleEnd, 17)
        let end = QuitPlan.windowEnd(now: now, settleEnd: window.settleEnd, outstandingDefaultWrites: 0, generationUnseen: false)
        XCTAssertEqual(QuitPlan.deferral(now: now, windowEnd: end, deadline: now + 3), 1.8, accuracy: 1e-9)
    }

    func testAChangeCarriedPastTheCapDefersQuitForItsSettlePeriod() {
        var window = LifecycleQuietWindow()
        for time in stride(from: 0.0, through: 14.0, by: 2.0) {
            window.noteChange(at: time)
        }
        window.noteChange(at: 15.5)
        XCTAssertTrue(window.hasCarriedChange)
        let now = 15.7
        XCTAssertFalse(window.isHolding(at: now), "a carried change makes the window itself stop holding")
        XCTAssertEqual(window.settleEnd, 18.5)
        let end = QuitPlan.windowEnd(now: now, settleEnd: window.settleEnd, outstandingDefaultWrites: 0, generationUnseen: false)
        XCTAssertEqual(QuitPlan.deferral(now: now, windowEnd: end, deadline: now + 3), 2.8, accuracy: 1e-9)
    }

    func testADeferralBelowTheResolutionIsNotScheduled() {
        XCTAssertEqual(QuitPlan.deferral(now: 100, windowEnd: 100 + QuitPlan.deferralResolution / 2, deadline: 103), 0)
    }

    func testTheDeferralIsNotCountedInTheWaitsBounds() {
        XCTAssertEqual(
            QuitPlan.steps.last,
            .waitForLifecycleStops(
                idleTimeout: QuitPlan.lifecycleStopIdleTimeout,
                ceiling: QuitPlan.lifecycleStopCeiling
            ),
            "the wait keeps its own bounds after a deferral"
        )
        XCTAssertFalse(QuitPlan.steps.contains { "\($0)".localizedCaseInsensitiveContains("defer") })
    }

    func testTheWaitOutlastsOneCallThatWaitsOutAHealthyConfigurationChange() {
        // One stop or destroy can wait about 1.5 s inside a healthy Bluetooth
        // configuration change. The idle bound must not read that call as a
        // server that does not answer, or Quit exits with it still in
        // coreaudiod.
        let longestHealthyCall: TimeInterval = 1.6
        XCTAssertGreaterThanOrEqual(QuitPlan.lifecycleStopIdleTimeout, longestHealthyCall * 1.5)
        XCTAssertGreaterThanOrEqual(
            QuitPlan.lifecycleStopCeiling,
            QuitPlan.lifecycleStopIdleTimeout + 2 * longestHealthyCall,
            "the ceiling leaves room for calls that wait out a chained pair of changes"
        )
    }

    // MARK: Sequence

    func testAQuitOutsideTheWindowTearsDownNow() {
        var sequence = QuitSequence()
        XCTAssertEqual(sequence.request { 0 }, .tearDownNow)
        XCTAssertEqual(sequence.phase, .tornDown)
        XCTAssertEqual(sequence.deferralEnded { 0 }, .nothing)
        XCTAssertFalse(sequence.willTerminate(), "the teardown runs once")
    }

    func testADeferralThatComesDueReadsTheWindowAgain() {
        var sequence = QuitSequence()
        XCTAssertEqual(sequence.request { 1.2 }, .deferTeardown(delay: 1.2))

        var readAgain = false
        XCTAssertEqual(sequence.request { readAgain = true; return 3 }, .alreadyDeferred)
        XCTAssertFalse(readAgain, "a second request does not move the deferral")

        XCTAssertEqual(sequence.deferralEnded { 0.9 }, .deferAgain(delay: 0.9), "a change noted since moved the end")
        XCTAssertEqual(sequence.phase, .deferring)
        XCTAssertEqual(sequence.deferralEnded { 0 }, .tearDown)
        XCTAssertEqual(sequence.phase, .tornDown)
        XCTAssertEqual(sequence.deferralEnded { 1 }, .nothing, "one teardown")
    }

    func testASecondQuitWhileDeferredChangesNothing() {
        var sequence = QuitSequence()
        _ = sequence.request { 2 }
        XCTAssertEqual(sequence.request { 2 }, .alreadyDeferred)
        XCTAssertEqual(sequence.deferralEnded { 0 }, .tearDown)
        XCTAssertEqual(sequence.deferralEnded { 0 }, .nothing, "one deferred teardown")
        XCTAssertEqual(sequence.request { 2 }, .alreadyTornDown)
        XCTAssertFalse(sequence.willTerminate())
    }

    func testATerminationThatNeverAskedTearsDownOnce() {
        var sequence = QuitSequence()
        XCTAssertTrue(sequence.willTerminate())
        XCTAssertFalse(sequence.willTerminate())

        var deferred = QuitSequence()
        _ = deferred.request { 3 }
        XCTAssertTrue(deferred.willTerminate(), "a termination during the deferral tears down then")
        XCTAssertEqual(deferred.deferralEnded { 1 }, .nothing, "and the deferral's end does nothing more")
    }
}
