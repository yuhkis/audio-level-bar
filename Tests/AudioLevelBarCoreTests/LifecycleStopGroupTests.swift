import Darwin
import Foundation
import XCTest
@testable import AudioLevelBarCore

final class LifecycleStopGroupTests: XCTestCase {
    func testWaitWithNothingToRunReturnsAtOnce() {
        let outcome = LifecycleStopGroup().wait(idleTimeout: 0, ceiling: 0)

        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(outcome.pending, [:])
        XCTAssertEqual(outcome.pendingDescription, "")
    }

    func testWaitReturnsOnceEveryStopHasRun() {
        let stops = LifecycleStopGroup()
        let lock = NSLock()
        var ran: Set<String> = []
        for label in ["meter", "system-output", "capture"] {
            let queue = DispatchQueue(label: "test.\(label)")
            stops.run(label: label, on: queue) { _ in
                lock.lock()
                ran.insert(label)
                lock.unlock()
            }
        }

        let outcome = stops.wait(idleTimeout: 5, ceiling: 5)
        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(outcome.pending, [:])
        lock.lock()
        XCTAssertEqual(ran, ["meter", "system-output", "capture"])
        lock.unlock()
    }

    func testWaitExtendsWhileStopsKeepProgressing() {
        let stops = LifecycleStopGroup()
        // Six HAL calls of 0.5 s each: 3 s in all, three times the idle
        // bound, with a call returning every 0.5 s.
        stops.run(label: "system-output", on: DispatchQueue(label: "test.slow")) { progress in
            for _ in 0..<6 {
                progress.report(.stopIOProc)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        let outcome = stops.wait(idleTimeout: 1, ceiling: 5)
        XCTAssertTrue(outcome.completed)
        XCTAssertGreaterThanOrEqual(outcome.waited, 2.5)
    }

    func testWaitGivesUpAfterTheIdleBoundWithNoProgress() {
        let stuckQueue = DispatchQueue(label: "test.stuck")
        let freeQueue = DispatchQueue(label: "test.free")
        let unblock = DispatchSemaphore(value: 0)
        // A HAL call that is not answering, ahead of the stop on its queue.
        stuckQueue.async {
            unblock.wait()
        }

        let stops = LifecycleStopGroup()
        let freeStopRan = DispatchSemaphore(value: 0)
        let stuckStopRan = DispatchSemaphore(value: 0)
        stops.run(label: "stuck", on: stuckQueue) { _ in
            stuckStopRan.signal()
        }
        stops.run(label: "free", on: freeQueue) { _ in
            freeStopRan.signal()
        }

        let outcome = stops.wait(idleTimeout: 0.3, ceiling: 5)
        XCTAssertFalse(outcome.completed)
        XCTAssertLessThan(outcome.waited, 2, "no progress ends the wait long before the ceiling")
        XCTAssertEqual(outcome.pending, ["stuck": .queued])
        XCTAssertEqual(freeStopRan.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            stuckStopRan.wait(timeout: .now()),
            .timedOut,
            "the stuck queue has not reached its stop"
        )

        unblock.signal()
        XCTAssertEqual(stuckStopRan.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(stops.wait(idleTimeout: 2, ceiling: 2).completed)
    }

    func testWaitNeverExceedsTheCeiling() {
        let stops = LifecycleStopGroup()
        let finish = DispatchSemaphore(value: 0)
        // A stop that keeps getting answers and never ends.
        stops.run(label: "capture", on: DispatchQueue(label: "test.endless")) { progress in
            while finish.wait(timeout: .now() + 0.05) == .timedOut {
                progress.report(.destroyIOProc)
            }
        }

        let outcome = stops.wait(idleTimeout: 0.5, ceiling: 1)
        finish.signal()
        XCTAssertFalse(outcome.completed)
        XCTAssertGreaterThanOrEqual(outcome.waited, 1)
        XCTAssertLessThan(outcome.waited, 2.5)
        XCTAssertEqual(outcome.pending, ["capture": .destroyIOProc])
    }

    func testOutcomeNamesThePendingLabelAndPhase() {
        let stops = LifecycleStopGroup()
        let unblock = DispatchSemaphore(value: 0)
        stops.run(label: "system-output", on: DispatchQueue(label: "test.inside")) { progress in
            progress.report(.stopIOProc)
            progress.report(.destroyIOProc)
            progress.report(.destroyAggregate)
            // Inside AudioHardwareDestroyAggregateDevice, not answering.
            unblock.wait()
        }
        stops.run(label: "microphone", on: DispatchQueue(label: "test.done")) { progress in
            progress.report(.stopIOProc)
        }

        let outcome = stops.wait(idleTimeout: 0.2, ceiling: 2)
        unblock.signal()
        XCTAssertFalse(outcome.completed)
        XCTAssertEqual(outcome.pending, ["system-output": .destroyAggregate])
        XCTAssertEqual(outcome.pendingDescription, "system-output:destroy-aggregate")
    }

    func testPendingStopsAreListedInLabelOrder() {
        let outcome = LifecycleStopGroup.Outcome(
            completed: false,
            pending: ["system-output": .queued, "microphone": .stopIOProc],
            waited: 1
        )

        XCTAssertEqual(outcome.pendingDescription, "microphone:stop-ioproc,system-output:queued")
    }

    func testStopsRunAtUserInteractiveQualityOfService() {
        let stops = LifecycleStopGroup()
        var observed = QOS_CLASS_UNSPECIFIED
        stops.run(
            label: "microphone",
            on: DispatchQueue(label: "test.user-initiated", qos: .userInitiated)
        ) { _ in
            observed = qos_class_self()
        }

        XCTAssertTrue(stops.wait(idleTimeout: 2, ceiling: 2).completed)
        XCTAssertEqual(observed, QOS_CLASS_USER_INTERACTIVE)
    }

    func testPhasesNameTheTeardownSteps() {
        XCTAssertEqual(LifecycleStopGroup.Phase(.readIsRunning).rawValue, "read-is-running")
        XCTAssertEqual(LifecycleStopGroup.Phase(.stop).rawValue, "stop-ioproc")
        XCTAssertEqual(LifecycleStopGroup.Phase(.destroyIOProc).rawValue, "destroy-ioproc")
        XCTAssertEqual(LifecycleStopGroup.Phase(.destroyAggregate).rawValue, "destroy-aggregate")
        XCTAssertEqual(LifecycleStopGroup.Phase(.destroyProcessTap).rawValue, "destroy-tap")
    }
}
