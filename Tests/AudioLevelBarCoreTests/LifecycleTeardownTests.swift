import XCTest
@testable import AudioLevelBarCore

final class LifecycleTeardownTests: XCTestCase {
    /// Runs the teardown to completion, answering the running read with
    /// `running`, and returns the steps in order.
    private func steps(
        of teardown: LifecycleTeardown,
        running: Bool = false,
        stoppingBefore interruption: LifecycleTeardown.Step? = nil
    ) -> (steps: [LifecycleTeardown.Step], remaining: LifecycleTeardown) {
        var teardown = teardown
        var steps: [LifecycleTeardown.Step] = []
        while let step = teardown.nextStep {
            if step == interruption {
                break
            }
            steps.append(step)
            if step == .readIsRunning {
                teardown.noteIsRunning(running)
            } else {
                teardown.complete(step)
            }
        }
        return (steps, teardown)
    }

    func testAStartedIOProcIsStoppedBeforeItIsDestroyed() {
        let result = steps(of: LifecycleTeardown(ioProc: .started, holdsAggregate: true, holdsTap: true))
        XCTAssertEqual(result.steps, [.stop, .destroyIOProc, .destroyAggregate, .destroyProcessTap])
        XCTAssertNil(result.remaining.nextStep)
    }

    func testAnIOProcThatNeverStartedIsDestroyedWithoutAStop() {
        XCTAssertEqual(
            steps(of: LifecycleTeardown(ioProc: .created, holdsAggregate: true, holdsTap: true)).steps,
            [.destroyIOProc, .destroyAggregate, .destroyProcessTap]
        )
    }

    func testStopInterruptedAfterIOProcStopKeepsAggregateAndTap() {
        let interrupted = steps(
            of: LifecycleTeardown(ioProc: .started, holdsAggregate: true, holdsTap: true),
            stoppingBefore: .destroyIOProc
        )
        XCTAssertEqual(interrupted.steps, [.stop])
        XCTAssertEqual(interrupted.remaining.ioProc, .created)
        XCTAssertTrue(interrupted.remaining.holdsAggregate)
        XCTAssertTrue(interrupted.remaining.holdsTap)

        // The release after the window does not stop the IOProc again.
        XCTAssertEqual(
            steps(of: interrupted.remaining).steps,
            [.destroyIOProc, .destroyAggregate, .destroyProcessTap]
        )
    }

    func testTapIsNeverDestroyedWhileItsAggregateExists() {
        let starts: [LifecycleTeardown.IOProc] = [
            .none, .created, .startUnconfirmed, .runningAfterUnconfirmedStart, .started
        ]
        for ioProc in starts {
            for running in [false, true] {
                var teardown = LifecycleTeardown(ioProc: ioProc, holdsAggregate: true, holdsTap: true)
                while let step = teardown.nextStep {
                    switch step {
                    case .destroyAggregate:
                        XCTAssertEqual(teardown.ioProc, .none, "an aggregate device goes only once its IOProc is gone")
                    case .destroyProcessTap:
                        XCTAssertFalse(teardown.holdsAggregate, "a tap goes only once its aggregate device is gone")
                    case .readIsRunning, .stop, .destroyIOProc:
                        XCTAssertTrue(teardown.holdsAggregate)
                        XCTAssertTrue(teardown.holdsTap)
                    }
                    if step == .readIsRunning {
                        teardown.noteIsRunning(running)
                    } else {
                        teardown.complete(step)
                    }
                }
            }
        }
    }

    func testAnInterruptedAggregateDestroyKeepsTheTap() {
        let interrupted = steps(
            of: LifecycleTeardown(ioProc: .none, holdsAggregate: true, holdsTap: true),
            stoppingBefore: .destroyAggregate
        )
        XCTAssertEqual(interrupted.steps, [])
        XCTAssertEqual(interrupted.remaining.nextStep, .destroyAggregate)

        XCTAssertEqual(steps(of: interrupted.remaining).steps, [.destroyAggregate, .destroyProcessTap])
    }

    func testFailedStartThatReportsRunningIsStoppedBeforeDestroy() {
        let result = steps(
            of: LifecycleTeardown(ioProc: .startUnconfirmed, holdsAggregate: true, holdsTap: true),
            running: true
        )
        XCTAssertEqual(
            result.steps,
            [.readIsRunning, .stop, .destroyIOProc, .destroyAggregate, .destroyProcessTap]
        )
    }

    func testFailedStartThatReportsNotRunningIsDestroyedWithoutAStop() {
        XCTAssertEqual(
            steps(of: LifecycleTeardown(ioProc: .startUnconfirmed), running: false).steps,
            [.readIsRunning, .destroyIOProc]
        )
    }

    func testTheStopAfterAFailedStartIsMarked() {
        var teardown = LifecycleTeardown(ioProc: .startUnconfirmed)
        XCTAssertFalse(teardown.stopFollowsUnconfirmedStart)
        teardown.noteIsRunning(true)
        XCTAssertTrue(teardown.stopFollowsUnconfirmedStart)
        teardown.complete(.stop)
        XCTAssertFalse(teardown.stopFollowsUnconfirmedStart)

        XCTAssertFalse(LifecycleTeardown(ioProc: .started).stopFollowsUnconfirmedStart)
    }

    func testTheRunningReadIsNotALifecycleCall() {
        XCTAssertFalse(LifecycleTeardown.Step.readIsRunning.isLifecycleCall)
        for step: LifecycleTeardown.Step in [.stop, .destroyIOProc, .destroyAggregate, .destroyProcessTap] {
            XCTAssertTrue(step.isLifecycleCall)
        }
    }

    func testARunningReadOutsideAnUnconfirmedStartChangesNothing() {
        var teardown = LifecycleTeardown(ioProc: .started)
        teardown.noteIsRunning(false)
        XCTAssertEqual(teardown.ioProc, .started)
    }

    func testNilTokenStopsRunToCompletion() {
        let generation = LifecycleHoldGeneration()
        let token = generation.current
        generation.advance()

        XCTAssertFalse(generation.allows(token), "a stop issued before the window armed is held")
        XCTAssertTrue(generation.allows(nil), "a stop the window does not hold, such as at Quit, is not")
        XCTAssertTrue(generation.allows(generation.current))
    }
}
