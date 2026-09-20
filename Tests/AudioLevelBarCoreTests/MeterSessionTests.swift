import XCTest
@testable import AudioLevelBarCore

final class MeterSessionTests: XCTestCase {
    private let builtIn: UInt32 = 41
    private let usb: UInt32 = 42

    private func evaluate(
        _ session: inout MeterSession,
        _ target: MeterSession.Target,
        holding: Bool = false,
        startsHeld: Bool = false,
        now: TimeInterval = 100
    ) -> MeterSession.Action? {
        session.handle(
            .evaluate(target: target, holding: holding, startsHeld: startsHeld || holding, now: now)
        )
    }

    private func runningSession(on deviceID: UInt32) -> MeterSession {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(deviceID)), .start(deviceID))
        XCTAssertNil(session.handle(.started(deviceID, now: 100)))
        return session
    }

    /// A session in every phase, on `builtIn` where the phase names a device.
    private func sessionsInEveryPhase() -> [MeterSession] {
        let stopped = MeterSession()

        var starting = MeterSession()
        XCTAssertEqual(evaluate(&starting, .device(builtIn)), .start(builtIn))

        let running = runningSession(on: builtIn)

        var invalidated = runningSession(on: builtIn)
        XCTAssertNil(invalidated.handle(.invalidated(builtIn, now: 100)))

        var failed = starting
        XCTAssertNil(failed.handle(.startFailed(builtIn, now: 100)))

        var refused = starting
        XCTAssertNil(refused.handle(.refusedAtStart(builtIn, .bluetooth, now: 100)))

        var interrupted = starting
        XCTAssertNil(interrupted.handle(.startInterrupted(builtIn)))

        var stopInterrupted = runningSession(on: builtIn)
        XCTAssertEqual(stopInterrupted.handle(.stopRequested), .stop)
        XCTAssertNil(stopInterrupted.handle(.stopInterrupted))

        var stalled = starting
        XCTAssertNil(evaluate(&stalled, .device(builtIn), now: 100 + MeterSession.startTimeout))

        let sessions = [
            stopped, starting, running, invalidated, failed, refused, interrupted, stopInterrupted, stalled
        ]
        XCTAssertEqual(
            sessions.map(\.phase),
            [
                .stopped,
                .starting(builtIn),
                .running(builtIn),
                .invalidated(builtIn, retryAt: 102),
                .failed(builtIn, attempts: 1, retryAt: 102),
                .refused(builtIn, .bluetooth),
                .interrupted(builtIn),
                .stopInterrupted,
                .stalled(builtIn)
            ]
        )
        return sessions
    }

    func testStartsHeldEvaluationStopsButNeverStarts() {
        let targets: [MeterSession.Target] = [.device(builtIn), .device(usb), .notMeasured(.bluetooth)]
        for session in sessionsInEveryPhase() {
            for target in targets {
                for now in [100.0, 1_000.0] {
                    var copy = session
                    let action = evaluate(&copy, target, startsHeld: true, now: now)
                    if case .start? = action {
                        XCTFail("\(session.phase) with \(target) at \(now) started")
                    }
                }
            }
        }

        // A meter on another device is stopped and the target not started.
        var moving = runningSession(on: builtIn)
        XCTAssertEqual(evaluate(&moving, .device(usb), startsHeld: true), .stop)
        XCTAssertEqual(moving.phase, .stopped)
        XCTAssertEqual(moving.display, .starting)
        XCTAssertNil(evaluate(&moving, .device(usb), startsHeld: true, now: 101))

        // A meter with nothing to measure is stopped.
        var bluetooth = runningSession(on: builtIn)
        XCTAssertEqual(evaluate(&bluetooth, .notMeasured(.bluetooth), startsHeld: true), .stop)

        // A meter already on the target stays.
        var staying = runningSession(on: builtIn)
        XCTAssertNil(evaluate(&staying, .device(builtIn), startsHeld: true))
        XCTAssertEqual(staying.phase, .running(builtIn))
    }

    func testStartsHeldStopsWhatAnotherDeviceStillHolds() {
        for session in sessionsInEveryPhase() {
            var copy = session
            let action = evaluate(&copy, .device(usb), startsHeld: true)
            switch session.phase {
            case .stopped, .refused, .starting, .stalled:
                // Nothing is held, a refusal created nothing, or a start has
                // not reported back.
                XCTAssertNil(action, "\(session.phase)")
            default:
                XCTAssertEqual(action, .stop, "\(session.phase)")
            }
        }
    }

    func testStartsHeldTargetChangeStartsAfterFullRelease() {
        var session = runningSession(on: builtIn)

        // The default moved; the release at the cap admits stops only.
        XCTAssertEqual(evaluate(&session, .device(usb), startsHeld: true, now: 115), .stop)
        // The rest of the settle period holds.
        XCTAssertNil(evaluate(&session, .device(usb), holding: true, now: 116))
        // The full release starts the meter on the new target.
        XCTAssertEqual(evaluate(&session, .device(usb), now: 118), .start(usb))
    }

    func testStartsHeldIssuesAStopTheWindowInterrupted() {
        var session = runningSession(on: builtIn)
        XCTAssertEqual(session.handle(.stopRequested), .stop)
        XCTAssertNil(session.handle(.stopInterrupted))

        XCTAssertEqual(evaluate(&session, .device(builtIn), startsHeld: true), .stop, "an owed stop is a stop")
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 104), .start(builtIn))
    }

    func testServiceRestartForgetsWhatTheMeterHeldAndStartsAgainAfterTheWindow() {
        for session in sessionsInEveryPhase() {
            var copy = session
            XCTAssertNil(copy.handle(.serviceRestarted), "nothing is issued to a server that restarted, \(session.phase)")
            XCTAssertEqual(copy.phase, .stopped)
            XCTAssertNil(evaluate(&copy, .device(builtIn), holding: true, now: 200))
            XCTAssertEqual(
                evaluate(&copy, .device(builtIn), now: 203),
                .start(builtIn),
                "rebuilt once starts are admitted, \(session.phase)"
            )
        }
    }

    func testDisplayBeforeTheFirstEvaluationIsStarting() {
        let session = MeterSession()
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertNil(session.target)
        XCTAssertEqual(session.display, .starting)
    }

    func testStartsFromStopped() {
        var session = MeterSession()

        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
        XCTAssertEqual(session.phase, .starting(builtIn))
        XCTAssertEqual(session.display, .starting)
        XCTAssertNil(evaluate(&session, .device(builtIn)), "a start in flight is not repeated")
    }

    func testStartedIsLive() {
        var session = runningSession(on: builtIn)

        XCTAssertEqual(session.phase, .running(builtIn))
        XCTAssertEqual(session.display, .live)
        XCTAssertNil(evaluate(&session, .device(builtIn)))
    }

    func testDefaultChangeWhileHoldingKeepsTheOldMeterAndSwitchesTheDisplay() {
        var session = runningSession(on: builtIn)

        XCTAssertNil(evaluate(&session, .device(usb), holding: true))
        XCTAssertEqual(session.phase, .running(builtIn))
        XCTAssertEqual(session.display, .starting)

        XCTAssertNil(evaluate(&session, .device(usb), holding: true, now: 101))
        XCTAssertEqual(evaluate(&session, .device(usb), now: 103), .start(usb))
        XCTAssertNil(evaluate(&session, .device(usb), now: 104), "the release starts exactly once")
        XCTAssertNil(session.handle(.started(usb, now: 100)))
        XCTAssertEqual(session.display, .live)
    }

    func testBluetoothTargetStopsAndIsNotMeasured() {
        var session = runningSession(on: builtIn)

        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth), holding: true))
        XCTAssertEqual(session.display, .notMeasured(.bluetooth))
        XCTAssertEqual(session.phase, .running(builtIn))

        XCTAssertEqual(evaluate(&session, .notMeasured(.bluetooth)), .stop)
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertEqual(session.display, .notMeasured(.bluetooth))
        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth)), "already stopped")
    }

    func testTargetFromTheOpenDecision() {
        XCTAssertEqual(
            MeterSession.Target.input(deviceID: 7, decision: .open(.unknownTransport)),
            .device(7)
        )
        XCTAssertEqual(
            MeterSession.Target.input(deviceID: 7, decision: .refuse(.bluetooth)),
            .notMeasured(.bluetooth)
        )
        XCTAssertEqual(
            MeterSession.Target.input(deviceID: 7, decision: .refuse(.aggregateWithBluetoothMember)),
            .notMeasured(.bluetooth)
        )
        XCTAssertEqual(
            MeterSession.Target.input(deviceID: 0, decision: .refuse(.noDevice)),
            .notMeasured(.noDevice)
        )
        XCTAssertEqual(
            MeterSession.Target.input(deviceID: 7, decision: .refuse(.transportNotRead)),
            .notMeasured(.transportNotRead)
        )
    }

    func testInvalidationWaitsForTheNextEvaluationAfterADelay() {
        var session = runningSession(on: builtIn)

        XCTAssertNil(session.handle(.invalidated(builtIn, now: 100)))
        XCTAssertEqual(session.phase, .invalidated(builtIn, retryAt: 102))
        XCTAssertEqual(session.display, .starting)

        XCTAssertNil(evaluate(&session, .device(builtIn), now: 100))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 101.9))
        XCTAssertNil(evaluate(&session, .device(builtIn), holding: true, now: 102))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 102), .start(builtIn))
    }

    func testInvalidationDuringStartWaitsForTheStartAndThenApplies() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))

        XCTAssertNil(session.handle(.invalidated(builtIn, now: 100)))
        XCTAssertEqual(session.phase, .starting(builtIn), "the start is still in flight")
        XCTAssertTrue(session.hasPendingInvalidation)
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 105), "nothing is issued behind the start")

        XCTAssertNil(session.handle(.started(builtIn, now: 100)))
        XCTAssertEqual(session.phase, .invalidated(builtIn, retryAt: 102))
        XCTAssertFalse(session.hasPendingInvalidation)
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 105), .start(builtIn))
    }

    func testAnInvalidatedStartThatNeverReportsStillStalls() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 101)))

        XCTAssertNil(evaluate(&session, .device(builtIn), now: 100 + MeterSession.startTimeout))
        XCTAssertTrue(session.isStalled)
    }

    func testInvalidationWhileStalledKeepsTheStall() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 110))
        XCTAssertTrue(session.isStalled)

        XCTAssertNil(session.handle(.invalidated(builtIn, now: 111)))
        XCTAssertEqual(session.phase, .stalled(builtIn))
        XCTAssertTrue(session.isStalled)
        XCTAssertTrue(session.hasStartInFlight)

        XCTAssertNil(evaluate(&session, .device(builtIn), now: 1_000))
        XCTAssertNil(evaluate(&session, .device(usb), now: 1_001))
        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth), now: 1_002))
        XCTAssertNil(session.handle(.stopRequested))
        XCTAssertEqual(session.phase, .stalled(builtIn))
    }

    func testStartedAfterInvalidationWhileStalledAppliesTheInvalidation() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 110))
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 111)))

        // coreaudiod answers again long after the invalidation.
        XCTAssertNil(session.handle(.started(builtIn, now: 140)))
        XCTAssertEqual(
            session.phase,
            .invalidated(builtIn, retryAt: 142),
            "the delay counts from the report, not from the invalidation"
        )
        XCTAssertNotEqual(session.display, .live)
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 141.9))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 142), .start(builtIn))
    }

    func testAPendingInvalidationIsDroppedWhenTheStartReportsAnythingButStarted() {
        var failed = MeterSession()
        XCTAssertEqual(evaluate(&failed, .device(builtIn)), .start(builtIn))
        XCTAssertNil(failed.handle(.invalidated(builtIn, now: 100)))
        XCTAssertNil(failed.handle(.startFailed(builtIn, now: 101)))
        XCTAssertEqual(failed.phase, .failed(builtIn, attempts: 1, retryAt: 103))
        XCTAssertFalse(failed.hasPendingInvalidation)

        var refused = MeterSession()
        XCTAssertEqual(evaluate(&refused, .device(builtIn)), .start(builtIn))
        XCTAssertNil(refused.handle(.invalidated(builtIn, now: 100)))
        XCTAssertNil(refused.handle(.refusedAtStart(builtIn, .bluetooth, now: 101)))
        XCTAssertEqual(refused.phase, .refused(builtIn, .bluetooth))
        XCTAssertFalse(refused.hasPendingInvalidation)

        var interrupted = MeterSession()
        XCTAssertEqual(evaluate(&interrupted, .device(builtIn)), .start(builtIn))
        XCTAssertNil(interrupted.handle(.invalidated(builtIn, now: 100)))
        XCTAssertNil(interrupted.handle(.startInterrupted(builtIn)))
        XCTAssertEqual(interrupted.phase, .interrupted(builtIn))
        XCTAssertFalse(interrupted.hasPendingInvalidation)

        var stopped = MeterSession()
        XCTAssertEqual(evaluate(&stopped, .device(builtIn)), .start(builtIn))
        XCTAssertNil(stopped.handle(.invalidated(builtIn, now: 100)))
        XCTAssertEqual(stopped.handle(.stopRequested), .stop)
        XCTAssertFalse(stopped.hasPendingInvalidation)

    }

    func testAPendingInvalidationSurvivesARetarget() {
        var retargeted = MeterSession()
        XCTAssertEqual(evaluate(&retargeted, .device(builtIn)), .start(builtIn))
        XCTAssertNil(retargeted.handle(.invalidated(builtIn, now: 100)))
        XCTAssertNil(evaluate(&retargeted, .device(usb), holding: true))
        XCTAssertTrue(retargeted.hasPendingInvalidation, "it belongs to the start in flight")
        XCTAssertNil(retargeted.handle(.started(builtIn, now: 100)))
        XCTAssertEqual(retargeted.phase, .invalidated(builtIn, retryAt: 102))
        XCTAssertEqual(evaluate(&retargeted, .device(usb), now: 102), .start(usb))
    }

    func testAPendingInvalidationSurvivesATargetThatFlapsBack() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 100)))
        XCTAssertNil(evaluate(&session, .device(usb), holding: true))
        XCTAssertNil(evaluate(&session, .device(builtIn), holding: true))

        XCTAssertNil(session.handle(.started(builtIn, now: 100)))
        XCTAssertEqual(
            session.phase,
            .invalidated(builtIn, retryAt: 102),
            "never a meter that reads running with its capture gate closed"
        )
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 102), .start(builtIn))
    }

    func testARetargetIssuesNothingWhileAStartIsInFlight() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))

        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth), now: 104), "no stop behind the start")
        XCTAssertNil(evaluate(&session, .device(usb), now: 105), "no start on another device behind it")
        XCTAssertNil(evaluate(&session, .device(usb), startsHeld: true, now: 106))
        XCTAssertEqual(session.phase, .starting(builtIn))

        XCTAssertNil(evaluate(&session, .device(usb), now: 110))
        XCTAssertEqual(session.phase, .stalled(builtIn), "a start that then hangs is still seen stalled")
    }

    func testTheEvaluationAfterTheStartReportsActsOnTheNewTarget() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(evaluate(&session, .device(usb), now: 101))

        XCTAssertNil(session.handle(.started(builtIn, now: 102)))
        XCTAssertEqual(session.phase, .running(builtIn))
        XCTAssertEqual(evaluate(&session, .device(usb), now: 103), .start(usb))

        var toNothing = MeterSession()
        XCTAssertEqual(evaluate(&toNothing, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(evaluate(&toNothing, .notMeasured(.bluetooth), now: 101))
        XCTAssertNil(toNothing.handle(.started(builtIn, now: 102)))
        XCTAssertEqual(evaluate(&toNothing, .notMeasured(.bluetooth), now: 103), .stop)
    }

    func testRepeatedInvalidationsNeverRestartBackToBack() {
        // A device whose listener fires on the meter's own start, evaluated
        // on every poll with no quiet window in between.
        var session = MeterSession()
        let now: TimeInterval = 100
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))

        var starts = 1
        for _ in 0..<20 {
            _ = session.handle(.started(builtIn, now: 100))
            _ = session.handle(.invalidated(builtIn, now: now))
            if evaluate(&session, .device(builtIn), now: now) != nil {
                starts += 1
            }
        }
        XCTAssertEqual(starts, 1)
    }

    func testInvalidationBackoffGrowsWhileTheDeviceKeepsInvalidating() {
        var session = MeterSession()
        var now: TimeInterval = 100
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))

        for delay: TimeInterval in [2, 4, 8, 8, 8] {
            XCTAssertNil(session.handle(.started(builtIn, now: 100)))
            XCTAssertNil(evaluate(&session, .device(builtIn), now: now + 1))
            XCTAssertNil(session.handle(.invalidated(builtIn, now: now + 1)))
            XCTAssertEqual(session.phase, .invalidated(builtIn, retryAt: now + 1 + delay))

            XCTAssertNil(evaluate(&session, .device(builtIn), now: now + 1 + delay - 0.1))
            now += 1 + delay
            XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
        }
    }

    func testStableRunStartsTheInvalidationBackoffOver() {
        var session = runningSession(on: builtIn)
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 100)))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 102), .start(builtIn))
        XCTAssertNil(session.handle(.started(builtIn, now: 100)))
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 102)))
        XCTAssertEqual(session.phase, .invalidated(builtIn, retryAt: 106))

        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 106), .start(builtIn))
        XCTAssertNil(session.handle(.started(builtIn, now: 100)))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 107))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 107 + MeterSession.stableRunDuration))

        XCTAssertNil(session.handle(.invalidated(builtIn, now: 140)))
        XCTAssertEqual(session.phase, .invalidated(builtIn, retryAt: 142))
    }

    func testTargetChangeStartsTheInvalidationBackoffOver() {
        var session = runningSession(on: builtIn)
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 100)))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 102), .start(builtIn))
        XCTAssertNil(session.handle(.started(builtIn, now: 100)))
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 102)))
        XCTAssertEqual(session.phase, .invalidated(builtIn, retryAt: 106))

        XCTAssertNil(evaluate(&session, .device(usb), holding: true, now: 103))
        XCTAssertEqual(
            evaluate(&session, .device(builtIn), now: 103),
            .start(builtIn),
            "a change of target lifts the wait"
        )
        XCTAssertNil(session.handle(.started(builtIn, now: 100)))
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 103)))
        XCTAssertEqual(session.phase, .invalidated(builtIn, retryAt: 105))
    }

    func testInvalidatedMeterStillStopsWhenNothingIsToBeMeasured() {
        var session = runningSession(on: builtIn)
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 100)))

        XCTAssertEqual(evaluate(&session, .notMeasured(.bluetooth), now: 100), .stop)
        XCTAssertEqual(session.phase, .stopped)
    }

    func testStartFailuresBackOffAndGiveUpAfterEightAttempts() {
        var session = MeterSession()
        var now: TimeInterval = 100
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))

        let expectedDelays: [TimeInterval] = [2, 4, 8, 8, 8, 8, 8]
        for (index, delay) in expectedDelays.enumerated() {
            let attempts = index + 1
            XCTAssertNil(session.handle(.startFailed(builtIn, now: now)))
            XCTAssertEqual(session.phase, .failed(builtIn, attempts: attempts, retryAt: now + delay))
            XCTAssertEqual(session.display, .starting)
            XCTAssertFalse(session.retriesExhausted)

            XCTAssertNil(evaluate(&session, .device(builtIn), now: now + delay - 0.1))
            XCTAssertNil(
                evaluate(&session, .device(builtIn), holding: true, now: now + delay),
                "a retry waits for the quiet window too"
            )
            now += delay
            XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
        }

        XCTAssertNil(session.handle(.startFailed(builtIn, now: now)))
        XCTAssertEqual(session.phase, .failed(builtIn, attempts: 8, retryAt: now + 8))
        XCTAssertTrue(session.retriesExhausted)
        XCTAssertNil(evaluate(&session, .device(builtIn), now: now + 1_000))
    }

    func testSuccessfulStartResetsTheFailureCount() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(session.handle(.startFailed(builtIn, now: 100)))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 102), .start(builtIn))
        XCTAssertNil(session.handle(.started(builtIn, now: 100)))
        XCTAssertNil(session.handle(.invalidated(builtIn, now: 102)))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 104), .start(builtIn))

        XCTAssertNil(session.handle(.startFailed(builtIn, now: 104)))
        XCTAssertEqual(session.phase, .failed(builtIn, attempts: 1, retryAt: 106))
    }

    func testTargetChangeResetsTheFailureCount() {
        var session = MeterSession()
        var now: TimeInterval = 100
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
        for _ in 0..<MeterSession.maximumStartAttempts {
            XCTAssertNil(session.handle(.startFailed(builtIn, now: now)))
            now += 8
            _ = evaluate(&session, .device(builtIn), now: now)
        }
        XCTAssertTrue(session.retriesExhausted)

        XCTAssertNil(evaluate(&session, .device(usb), holding: true, now: now))
        XCTAssertFalse(session.retriesExhausted)
        XCTAssertNil(evaluate(&session, .device(builtIn), holding: true, now: now))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
        XCTAssertNil(session.handle(.startFailed(builtIn, now: now)))
        XCTAssertEqual(session.phase, .failed(builtIn, attempts: 1, retryAt: now + 2))
    }

    func testARequestedStopStartsAnExhaustedSessionOverAndItsStartWaitsForAnEvaluationThatAdmitsStarts() {
        var session = MeterSession()
        var now: TimeInterval = 100
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
        for _ in 0..<MeterSession.maximumStartAttempts {
            XCTAssertNil(session.handle(.startFailed(builtIn, now: now)))
            now += MeterSession.maximumRetryDelay
            _ = evaluate(&session, .device(builtIn), now: now)
        }
        XCTAssertTrue(session.retriesExhausted)

        // The owner's Retry. A failed start left nothing open, so the owner
        // does not issue the stop it gets back.
        XCTAssertEqual(session.handle(.stopRequested), .stop)
        XCTAssertFalse(session.retriesExhausted)
        XCTAssertEqual(session.display, .starting)
        XCTAssertNil(evaluate(&session, .device(builtIn), holding: true, now: now), "the window holds the start")
        XCTAssertNil(
            evaluate(&session, .device(builtIn), startsHeld: true, now: now),
            "and so does a release that admits stops only"
        )
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))

        XCTAssertNil(session.handle(.startFailed(builtIn, now: now)))
        XCTAssertEqual(session.phase, .failed(builtIn, attempts: 1, retryAt: now + 2), "counted from one")
    }

    func testFailedStartStillStopsWhenNothingIsToBeMeasured() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
        XCTAssertNil(session.handle(.startFailed(builtIn, now: 100)))

        XCTAssertEqual(evaluate(&session, .notMeasured(.notAuthorized)), .stop)
        XCTAssertEqual(session.phase, .stopped)
    }

    func testRefusalAtStartDoesNotRetryUntilTheTargetChanges() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))

        XCTAssertNil(session.handle(.refusedAtStart(builtIn, .bluetooth, now: 100)))
        XCTAssertEqual(session.phase, .refused(builtIn, .bluetooth))
        XCTAssertEqual(session.display, .notMeasured(.bluetooth))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 200))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 10_000))

        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth)), "a refusal opened nothing to stop")
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
    }

    func testTransportNotReadRefusalRetriesAfterBackoff() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))

        XCTAssertNil(session.handle(.refusedAtStart(builtIn, .transportNotRead, now: 100)))
        XCTAssertEqual(session.phase, .failed(builtIn, attempts: 1, retryAt: 102))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 101.9))
        XCTAssertNil(evaluate(&session, .device(builtIn), holding: true, now: 102))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 102), .start(builtIn))

        XCTAssertNil(session.handle(.refusedAtStart(builtIn, .transportNotRead, now: 102)))
        XCTAssertEqual(session.phase, .failed(builtIn, attempts: 2, retryAt: 106))
    }

    func testTransportNotReadRefusalsCountTowardTheAttemptCap() {
        var session = MeterSession()
        var now: TimeInterval = 100
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
        for attempt in 1...MeterSession.maximumStartAttempts {
            XCTAssertNil(session.handle(.refusedAtStart(builtIn, .transportNotRead, now: now)))
            now += MeterSession.maximumRetryDelay
            if attempt < MeterSession.maximumStartAttempts {
                XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
            }
        }
        XCTAssertTrue(session.retriesExhausted)
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 10_000))
    }

    func testAnAggregateMemberOnlyTheOpenCouldNotResolveIsRetriedAndCountsTowardTheAttemptCap() {
        var session = MeterSession()
        var now: TimeInterval = 100
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
        XCTAssertNil(session.handle(.refusedAtStart(builtIn, .aggregateWithUnresolvedMember, now: now)))
        XCTAssertEqual(
            session.phase,
            .failed(builtIn, attempts: 1, retryAt: now + 2),
            "the poll judged the device open, so this is a read to retry, not a refusal to latch"
        )
        XCTAssertNil(evaluate(&session, .device(builtIn), now: now + 1), "not before its delay")
        for attempt in 1...MeterSession.maximumStartAttempts {
            now += MeterSession.maximumRetryDelay
            if attempt < MeterSession.maximumStartAttempts {
                XCTAssertEqual(evaluate(&session, .device(builtIn), now: now), .start(builtIn))
                XCTAssertNil(session.handle(.refusedAtStart(builtIn, .aggregateWithUnresolvedMember, now: now)))
            }
        }
        XCTAssertTrue(session.retriesExhausted)
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 10_000))
    }

    func testBluetoothRefusalStillLatches() {
        for refusal: InputOpenRefusal in [.bluetooth, .aggregateWithBluetoothMember] {
            var session = MeterSession()
            XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
            XCTAssertNil(session.handle(.refusedAtStart(builtIn, refusal, now: 100)))
            XCTAssertEqual(session.phase, .refused(builtIn, .bluetooth))
            XCTAssertNil(evaluate(&session, .device(builtIn), now: 10_000))
            XCTAssertFalse(session.retriesExhausted)
        }
    }

    func testHandOffIsRefusedWhileAStartIsInFlight() {
        let inFlight = sessionsInEveryPhase().filter(\.hasStartInFlight).map(\.phase)
        XCTAssertEqual(inFlight, [.starting(builtIn), .stalled(builtIn)])
    }

    func testRefusalIsLiftedByATargetChangeDuringTheHold() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
        XCTAssertNil(session.handle(.refusedAtStart(builtIn, .aggregateWithBluetoothMember, now: 100)))

        XCTAssertNil(evaluate(&session, .device(usb), holding: true))
        XCTAssertNil(evaluate(&session, .device(builtIn), holding: true))
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
    }

    func testStaleEventsAreIgnored() {
        var session = runningSession(on: builtIn)
        let before = session

        XCTAssertNil(session.handle(.started(usb, now: 100)))
        XCTAssertNil(session.handle(.startFailed(usb, now: 100)))
        XCTAssertNil(session.handle(.refusedAtStart(usb, .bluetooth, now: 100)))
        XCTAssertNil(session.handle(.invalidated(usb, now: 100)))
        XCTAssertNil(session.handle(.startFailed(builtIn, now: 100)), "only a start in flight can fail")
        XCTAssertNil(session.handle(.refusedAtStart(builtIn, .bluetooth, now: 100)))
        XCTAssertNil(session.handle(.startInterrupted(usb)))
        XCTAssertNil(session.handle(.startInterrupted(builtIn)), "only a start in flight is interrupted")
        XCTAssertNil(session.handle(.stopInterrupted), "only a stop can be interrupted")
        XCTAssertEqual(session, before)

        XCTAssertEqual(evaluate(&session, .device(usb)), .start(usb))
        XCTAssertNil(session.handle(.started(builtIn, now: 100)), "the replaced meter's late event")
        XCTAssertEqual(session.phase, .starting(usb))

        XCTAssertNil(
            evaluate(&session, .notMeasured(.noDevice)),
            "nothing is issued behind the start in flight"
        )
        XCTAssertNil(session.handle(.started(usb, now: 100)))
        XCTAssertEqual(session.phase, .running(usb))
        XCTAssertEqual(evaluate(&session, .notMeasured(.noDevice)), .stop)
        XCTAssertNil(session.handle(.started(usb, now: 100)))
        XCTAssertNil(session.handle(.invalidated(usb, now: 100)))
        XCTAssertEqual(session.phase, .stopped)
    }

    func testStopRequestedStops() {
        var session = runningSession(on: builtIn)

        XCTAssertEqual(session.handle(.stopRequested), .stop)
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertNil(evaluate(&session, .notMeasured(.handedOff)))
        XCTAssertEqual(session.display, .notMeasured(.handedOff))
    }

    func testStopRequestedIsNotHeldByTheWindow() {
        var session = runningSession(on: builtIn)
        XCTAssertNil(evaluate(&session, .device(usb), holding: true))

        XCTAssertEqual(session.handle(.stopRequested), .stop)
        XCTAssertEqual(session.phase, .stopped)
    }

    func testInterruptedStartStartsAgainAfterTheWindow() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))

        XCTAssertNil(session.handle(.startInterrupted(builtIn)))
        XCTAssertEqual(session.phase, .interrupted(builtIn))
        XCTAssertEqual(session.display, .starting)
        XCTAssertNil(session.handle(.started(builtIn, now: 100)), "nothing from the abandoned start counts")
        XCTAssertEqual(session.phase, .interrupted(builtIn))

        XCTAssertNil(evaluate(&session, .device(builtIn), holding: true))
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
    }

    func testInterruptedStartIsStoppedWhenNothingIsToBeMeasured() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn)), .start(builtIn))
        XCTAssertNil(session.handle(.startInterrupted(builtIn)))

        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth), holding: true))
        XCTAssertEqual(
            evaluate(&session, .notMeasured(.bluetooth)),
            .stop,
            "whatever the abandoned start created is released after the window"
        )
        XCTAssertEqual(session.phase, .stopped)
    }

    func testInterruptedStopIsIssuedAgainAfterTheWindow() {
        var session = runningSession(on: builtIn)
        XCTAssertEqual(evaluate(&session, .notMeasured(.bluetooth)), .stop)

        XCTAssertNil(session.handle(.stopInterrupted))
        XCTAssertEqual(session.phase, .stopInterrupted)
        XCTAssertEqual(session.display, .notMeasured(.bluetooth))

        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth), holding: true))
        XCTAssertEqual(session.phase, .stopInterrupted)
        XCTAssertEqual(
            evaluate(&session, .notMeasured(.bluetooth)),
            .stop,
            "what the meter kept is stopped after the window"
        )
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth)), "and only once")
    }

    func testInterruptedStopGivesWayToAStartOnTheTarget() {
        var session = runningSession(on: builtIn)
        XCTAssertEqual(session.handle(.stopRequested), .stop)
        XCTAssertNil(session.handle(.stopInterrupted))

        XCTAssertNil(evaluate(&session, .device(usb), holding: true))
        XCTAssertEqual(session.display, .starting)
        XCTAssertEqual(
            evaluate(&session, .device(usb)),
            .start(usb),
            "a start releases what the meter held before it opens the device"
        )
    }

    func testStopInterruptedIsIgnoredOnceAStartReplacedTheStop() {
        var session = runningSession(on: builtIn)
        XCTAssertEqual(evaluate(&session, .notMeasured(.noDevice)), .stop)
        XCTAssertEqual(evaluate(&session, .device(usb)), .start(usb))

        XCTAssertNil(session.handle(.stopInterrupted))
        XCTAssertEqual(session.phase, .starting(usb))
    }

    func testInterruptionKeepsTheFailureCount() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(session.handle(.startFailed(builtIn, now: 100)))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 102), .start(builtIn))

        XCTAssertNil(session.handle(.startInterrupted(builtIn)))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 103), .start(builtIn))
        XCTAssertNil(session.handle(.startFailed(builtIn, now: 103)))
        XCTAssertEqual(session.phase, .failed(builtIn, attempts: 2, retryAt: 107))
    }

    func testAStartThatNeverReportsBackStallsAfterTheTimeout() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))

        XCTAssertNil(evaluate(&session, .device(builtIn), now: 100 + MeterSession.startTimeout - 0.1))
        XCTAssertFalse(session.isStalled)
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 100 + MeterSession.startTimeout))
        XCTAssertTrue(session.isStalled)
        XCTAssertEqual(session.phase, .stalled(builtIn))
        XCTAssertEqual(session.display, .starting)
    }

    func testAStallIsNoticedWhileTheWindowHolds() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))

        XCTAssertNil(evaluate(&session, .device(usb), holding: true, now: 110))
        XCTAssertTrue(session.isStalled)
    }

    func testAStalledStartIssuesNoFurtherHALWork() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 110))
        XCTAssertTrue(session.isStalled)

        XCTAssertNil(evaluate(&session, .device(usb), now: 111), "no start on another device")
        XCTAssertNil(evaluate(&session, .notMeasured(.bluetooth), now: 112), "no teardown either")
        XCTAssertNil(session.handle(.stopRequested), "not even for a hand-off")
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 1_000))
        XCTAssertEqual(session.phase, .stalled(builtIn))
    }

    func testAStalledStartThatReportsIsHandledAsUsual() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 110))

        XCTAssertNil(session.handle(.started(builtIn, now: 100)))
        XCTAssertEqual(session.phase, .running(builtIn))
        XCTAssertEqual(session.display, .live)
        XCTAssertEqual(evaluate(&session, .notMeasured(.bluetooth), now: 111), .stop)

        XCTAssertEqual(evaluate(&session, .device(usb), now: 200), .start(usb))
        XCTAssertNil(evaluate(&session, .device(usb), now: 210))
        XCTAssertTrue(session.isStalled)
        XCTAssertNil(session.handle(.startFailed(usb, now: 230)))
        XCTAssertEqual(session.phase, .failed(usb, attempts: 1, retryAt: 232))
    }

    func testTheTimeoutCountsFromTheLatestStart() {
        var session = MeterSession()
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 100), .start(builtIn))
        XCTAssertNil(session.handle(.startFailed(builtIn, now: 101)))
        XCTAssertEqual(evaluate(&session, .device(builtIn), now: 103), .start(builtIn))

        XCTAssertNil(evaluate(&session, .device(builtIn), now: 112.9))
        XCTAssertFalse(session.isStalled)
        XCTAssertNil(evaluate(&session, .device(builtIn), now: 113))
        XCTAssertTrue(session.isStalled)
    }

    func testReasonFromRefusal() {
        XCTAssertEqual(MeterNotMeasuredReason(.noDevice), .noDevice)
        XCTAssertEqual(MeterNotMeasuredReason(.transportNotRead), .transportNotRead)
        XCTAssertEqual(MeterNotMeasuredReason(.bluetooth), .bluetooth)
        XCTAssertEqual(MeterNotMeasuredReason(.aggregateWithBluetoothMember), .bluetooth)
        XCTAssertEqual(MeterNotMeasuredReason(.aggregateWithUnresolvedMember), .bluetooth)
    }
}
