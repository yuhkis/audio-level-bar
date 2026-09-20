import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// The order of the meters' HAL lifecycle calls against the quiet window's
/// generation, through a fake that never reaches coreaudiod.
///
/// A window arming is simulated by advancing the generation, either inside a
/// chosen fake call or while the meter's lifecycle queue is suspended with a
/// stop already issued.
final class LifecycleCallOrderTests: XCTestCase {
    private let timeout: TimeInterval = 5
    private let microphone: AudioDeviceID = 41
    private let otherMicrophone: AudioDeviceID = 42
    private let tap = FakeHALLifecycleCalls.tapID
    private let aggregate = FakeHALLifecycleCalls.aggregateID

    // MARK: Microphone meter

    func testStartIsAbandonedBeforeAudioDeviceStartWhenAWindowArmsAfterCreate() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.onCall = { call in
            if case .createIOProc = call {
                generation.advance()
            }
        }
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)

        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .interrupted(microphone))

        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(microphone)])
        XCTAssertEqual(events.values, [.interrupted(microphone)])

        // After the window, the owner's stop releases what the start created,
        // which never started.
        hal.onCall = nil
        XCTAssertEqual(stopAndWait(meter), .stopped)
        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(microphone), .destroyIOProc(microphone)])
    }

    func testStopIssuedBeforeAWindowReleasesNothingInsideIt() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)
        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .started(microphone))
        let callsWhileRunning = hal.calls

        // The stop takes the generation now; the window arms before the
        // lifecycle queue reaches it.
        meter.lifecycleQueue.suspend()
        let outcome = expectation(description: "stop outcome")
        var stopOutcome: MicrophoneMeter.StopOutcome?
        meter.stop { result in
            stopOutcome = result
            outcome.fulfill()
        }
        generation.advance()
        meter.lifecycleQueue.resume()
        wait(for: [outcome], timeout: timeout)

        XCTAssertEqual(stopOutcome, .interrupted)
        XCTAssertEqual(hal.calls, callsWhileRunning, "nothing is stopped, destroyed or unlistened inside the window")
        waitForMicrophoneEvent(events, .stopInterrupted)

        // The stop after the window releases it.
        XCTAssertEqual(stopAndWait(meter), .stopped)
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .stop(microphone), .destroyIOProc(microphone)]
        )
    }

    func testFailedStartReleaseWaitsForTheWindow() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.startStatus = kAudioHardwareUnspecifiedError
        hal.onCall = { call in
            if case .start = call {
                // The start waited in coreaudiod long enough for a window to
                // arm, then failed.
                generation.advance()
            }
        }
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)

        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .interrupted(microphone))

        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(microphone), .start(microphone)])
        XCTAssertFalse(hal.calls.contains(.removePropertyListener(microphone)))

        hal.onCall = nil
        XCTAssertEqual(stopAndWait(meter), .stopped)
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .destroyIOProc(microphone)],
            "the IOProc did not report running after its failed start, so it is destroyed without a stop"
        )
    }

    func testFailedStartWithoutAWindowIsReleasedAtOnce() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.startStatus = kAudioHardwareUnspecifiedError
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)

        meter.start(deviceID: microphone)
        let failed = expectation(description: "failed")
        events.onAppend = { event in
            if case .failed(self.microphone, _) = event {
                failed.fulfill()
            }
        }
        wait(for: [failed], timeout: timeout)

        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .destroyIOProc(microphone)]
        )
    }

    func testSupersededStartLeavesTheReleaseToTheNewerCall() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let reachedCreate = DispatchSemaphore(value: 0)
        let continueCreate = DispatchSemaphore(value: 0)
        let firstMicrophone = microphone
        hal.onCall = { call in
            if call == .createIOProc(firstMicrophone) {
                reachedCreate.signal()
                _ = continueCreate.wait(timeout: .now() + 5)
            }
        }
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)

        meter.start(deviceID: microphone)
        XCTAssertEqual(reachedCreate.wait(timeout: .now() + timeout), .success)
        // A newer start lands while the first is inside its create.
        meter.start(deviceID: otherMicrophone)
        continueCreate.signal()
        waitForMicrophoneEvent(events, .started(otherMicrophone))

        XCTAssertEqual(
            hal.lifecycleCalls,
            [
                .createIOProc(microphone),
                .destroyIOProc(microphone),
                .createIOProc(otherMicrophone),
                .start(otherMicrophone)
            ],
            "the superseded start neither starts nor releases; the newer call destroys it once"
        )
        XCTAssertEqual(events.values, [.started(otherMicrophone)])
    }

    func testSupersededStartInsideAWindowReleasesNothingItself() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let reachedCreate = DispatchSemaphore(value: 0)
        let continueCreate = DispatchSemaphore(value: 0)
        let firstMicrophone = microphone
        hal.onCall = { call in
            if call == .createIOProc(firstMicrophone) {
                reachedCreate.signal()
                _ = continueCreate.wait(timeout: .now() + 5)
            }
        }
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)

        meter.start(deviceID: microphone)
        XCTAssertEqual(reachedCreate.wait(timeout: .now() + timeout), .success)
        // A newer start lands while the first is inside its create, and a
        // window arms before either reaches its next check.
        meter.start(deviceID: otherMicrophone)
        generation.advance()
        continueCreate.signal()
        waitForMicrophoneEvent(events, .interrupted(otherMicrophone))
        meter.lifecycleQueue.sync {}

        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone)],
            "neither the superseded start nor the newer one destroys inside the window"
        )
        XCTAssertEqual(events.values, [.interrupted(otherMicrophone)])

        // After the window, the next start releases what the first built.
        hal.onCall = nil
        meter.start(deviceID: otherMicrophone)
        waitForMicrophoneEvent(events, .started(otherMicrophone))
        XCTAssertEqual(
            hal.lifecycleCalls,
            [
                .createIOProc(microphone),
                .destroyIOProc(microphone),
                .createIOProc(otherMicrophone),
                .start(otherMicrophone)
            ]
        )
    }

    func testMicrophoneStartIsAbandonedWhenAWindowArmsDuringTheFormatRead() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let target = microphone
        hal.onRead = { read in
            if read == .inputStreamFormat(target) {
                generation.advance()
            }
        }
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)

        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .interrupted(microphone))

        XCTAssertEqual(hal.lifecycleCalls, [], "no IOProc is created after a window armed in the read before it")
    }

    func testMicrophoneMeterForgetsWhatItHeldAfterAServiceRestartWithoutAHALCall() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)
        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .started(microphone))
        let callsWhileRunning = hal.calls

        meter.forgetAfterServiceRestart()
        meter.lifecycleQueue.sync {}
        XCTAssertEqual(hal.calls, callsWhileRunning, "nothing is stopped, destroyed or unlistened")

        XCTAssertEqual(stopAndWait(meter), .stopped)
        XCTAssertEqual(hal.calls, callsWhileRunning, "a later stop has nothing left to release")

        events.values.removeAll()
        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .started(microphone))
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .createIOProc(microphone), .start(microphone)],
            "the start after the window creates anew"
        )
    }

    // MARK: System output meter

    func testSystemOutputMeterForgetsWhatItHeldAfterAServiceRestartWithoutAHALCall() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let started = expectation(description: "started")
        meter.onStarted = { started.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [started], timeout: timeout)
        let built = hal.lifecycleCalls

        meter.forgetAfterServiceRestart()
        meter.lifecycleQueue.sync {}
        meter.stop()
        meter.lifecycleQueue.sync {}
        XCTAssertEqual(hal.lifecycleCalls, built, "the tap, aggregate and IOProc are neither stopped nor destroyed")

        let rebuilt = expectation(description: "rebuilt")
        meter.onStarted = { rebuilt.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [rebuilt], timeout: timeout)
        XCTAssertEqual(hal.lifecycleCalls, built + built, "the rebuild destroys nothing first and creates anew")
    }

    func testSystemOutputStartIsAbandonedBeforeAudioDeviceStartWhenAWindowArmsAfterCreate() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.onCall = { call in
            if case .createIOProc = call {
                generation.advance()
            }
        }
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let interrupted = expectation(description: "interrupted")
        meter.onInterrupted = { interrupted.fulfill() }
        meter.onStarted = { XCTFail("started inside the window") }
        meter.onError = { XCTFail("unexpected error \($0)") }

        meter.start(deviceUID: "output")
        wait(for: [interrupted], timeout: timeout)

        XCTAssertEqual(hal.lifecycleCalls, [.createProcessTap, .createAggregate, .createIOProc(aggregate)])

        hal.onCall = nil
        meter.stop()
        meter.lifecycleQueue.sync {}
        XCTAssertEqual(
            hal.lifecycleCalls,
            [
                .createProcessTap,
                .createAggregate,
                .createIOProc(aggregate),
                .destroyIOProc(aggregate),
                .destroyAggregate(aggregate),
                .destroyProcessTap(tap)
            ]
        )
    }

    func testSystemOutputSupersededStartInsideAWindowReleasesNothing() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let reachedCreate = DispatchSemaphore(value: 0)
        let continueCreate = DispatchSemaphore(value: 0)
        let aggregateID = aggregate
        hal.onCall = { call in
            if call == .createIOProc(aggregateID) {
                reachedCreate.signal()
                _ = continueCreate.wait(timeout: .now() + 5)
            }
        }
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let interrupted = expectation(description: "interrupted")
        meter.onInterrupted = { interrupted.fulfill() }
        meter.onStarted = { XCTFail("started inside the window") }
        meter.onError = { XCTFail("unexpected error \($0)") }

        meter.start(deviceUID: "output")
        XCTAssertEqual(reachedCreate.wait(timeout: .now() + timeout), .success)
        meter.start(deviceUID: "output")
        generation.advance()
        continueCreate.signal()
        wait(for: [interrupted], timeout: timeout)
        meter.lifecycleQueue.sync {}

        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createProcessTap, .createAggregate, .createIOProc(aggregate)],
            "no stop or destroy inside the window, from either start"
        )
    }

    func testSystemOutputStartIsAbandonedWhenAWindowArmsDuringTheDefaultOutputRead() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.onRead = { read in
            if read == .defaultOutputDeviceID {
                generation.advance()
            }
        }
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let interrupted = expectation(description: "interrupted")
        meter.onInterrupted = { interrupted.fulfill() }
        meter.onStarted = { XCTFail("started inside the window") }

        meter.start(deviceUID: "output")
        wait(for: [interrupted], timeout: timeout)

        XCTAssertEqual(hal.lifecycleCalls, [], "no tap is created after a window armed in the read before it")
    }

    func testSystemOutputStartIsAbandonedBeforeTheAggregateWhenAWindowArmsAtTheTapCreate() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.onCall = { call in
            if call == .createProcessTap {
                generation.advance()
            }
        }
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let interrupted = expectation(description: "interrupted")
        meter.onInterrupted = { interrupted.fulfill() }
        meter.onStarted = { XCTFail("started inside the window") }

        meter.start(deviceUID: "output")
        wait(for: [interrupted], timeout: timeout)
        XCTAssertEqual(hal.lifecycleCalls, [.createProcessTap])

        hal.onCall = nil
        meter.stop()
        meter.lifecycleQueue.sync {}
        XCTAssertEqual(hal.lifecycleCalls, [.createProcessTap, .destroyProcessTap(tap)])
    }

    func testSystemOutputStopIssuedBeforeAWindowReleasesNothingInsideIt() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let started = expectation(description: "started")
        meter.onStarted = { started.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [started], timeout: timeout)
        let callsWhileRunning = hal.lifecycleCalls

        let stopInterrupted = expectation(description: "stop interrupted")
        meter.onStopInterrupted = { stopInterrupted.fulfill() }
        meter.lifecycleQueue.suspend()
        meter.stop()
        generation.advance()
        meter.lifecycleQueue.resume()
        wait(for: [stopInterrupted], timeout: timeout)

        XCTAssertEqual(hal.lifecycleCalls, callsWhileRunning)

        meter.stop()
        meter.lifecycleQueue.sync {}
        XCTAssertEqual(
            hal.lifecycleCalls,
            callsWhileRunning + [
                .stop(aggregate),
                .destroyIOProc(aggregate),
                .destroyAggregate(aggregate),
                .destroyProcessTap(tap)
            ]
        )
    }

    func testSystemOutputFailedStartReleaseWaitsForTheWindow() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.startStatus = kAudioHardwareUnspecifiedError
        hal.onCall = { call in
            if case .start = call {
                generation.advance()
            }
        }
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let interrupted = expectation(description: "interrupted")
        meter.onInterrupted = { interrupted.fulfill() }
        meter.onError = { XCTFail("a failure inside the window is reported as interrupted, not \($0)") }

        meter.start(deviceUID: "output")
        wait(for: [interrupted], timeout: timeout)

        let built: [FakeHALLifecycleCalls.Call] = [
            .createProcessTap,
            .createAggregate,
            .createIOProc(aggregate),
            .start(aggregate)
        ]
        XCTAssertEqual(hal.lifecycleCalls, built, "nothing is destroyed inside the window")

        hal.onCall = nil
        meter.stop()
        meter.lifecycleQueue.sync {}
        XCTAssertEqual(
            hal.lifecycleCalls,
            built + [.destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)]
        )
    }

    func testSystemOutputFailedStartWithoutAWindowIsReleasedAtOnce() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.startStatus = kAudioHardwareUnspecifiedError
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let failed = expectation(description: "failed")
        meter.onError = { _ in failed.fulfill() }
        meter.onInterrupted = { XCTFail("no window armed") }

        meter.start(deviceUID: "output")
        wait(for: [failed], timeout: timeout)

        XCTAssertEqual(
            hal.lifecycleCalls,
            [
                .createProcessTap,
                .createAggregate,
                .createIOProc(aggregate),
                .start(aggregate),
                .destroyIOProc(aggregate),
                .destroyAggregate(aggregate),
                .destroyProcessTap(tap)
            ]
        )
    }

    func testSystemOutputRebuildForAnOutputThatMovedTouchesNothing() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let started = expectation(description: "started")
        meter.onStarted = { started.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [started], timeout: timeout)
        let callsWhileRunning = hal.lifecycleCalls

        // The default output moved after the rebuild was decided.
        hal.defaultOutputUID = "headset"
        let moved = expectation(description: "output moved")
        meter.onOutputMoved = { moved.fulfill() }
        meter.onStarted = { XCTFail("started for an output that is no longer the default") }
        meter.onInterrupted = { XCTFail("reported as a window interruption") }
        meter.start(deviceUID: "output")
        wait(for: [moved], timeout: timeout)

        XCTAssertEqual(
            hal.lifecycleCalls,
            callsWhileRunning,
            "the running tap is neither stopped nor destroyed, and nothing is created"
        )
    }

    func testSystemOutputRebuildWhoseDefaultOutputCannotBeReadTouchesNothing() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.defaultOutputUID = nil
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let moved = expectation(description: "output moved")
        meter.onOutputMoved = { moved.fulfill() }
        meter.onError = { XCTFail("unexpected error \($0)") }

        meter.start(deviceUID: "output")
        wait(for: [moved], timeout: timeout)

        XCTAssertEqual(hal.lifecycleCalls, [])
    }

    // MARK: A window arming in the middle of a teardown

    func testMicrophoneStopInterruptedAfterAudioDeviceStopKeepsTheIOProc() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)
        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .started(microphone))

        hal.onCall = { call in
            if call == .stop(self.microphone) {
                generation.advance()
            }
        }
        XCTAssertEqual(stopAndWait(meter), .interrupted)
        waitForMicrophoneEvent(events, .stopInterrupted)
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .stop(microphone)],
            "the IOProc is not destroyed inside the window"
        )

        hal.onCall = nil
        XCTAssertEqual(stopAndWait(meter), .stopped)
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .stop(microphone), .destroyIOProc(microphone)],
            "the stop after the window destroys the IOProc without stopping it again"
        )
    }

    func testMicrophoneStartStopsAtAWindowArmedWhileItReleasesThePreviousMeter() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)
        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .started(microphone))

        hal.onCall = { call in
            if call == .stop(self.microphone) {
                generation.advance()
            }
        }
        meter.start(deviceID: otherMicrophone)
        waitForMicrophoneEvent(events, .interrupted(otherMicrophone))
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .stop(microphone)],
            "neither the destroy nor the new create runs inside the window"
        )

        hal.onCall = nil
        meter.start(deviceID: otherMicrophone)
        waitForMicrophoneEvent(events, .started(otherMicrophone))
        XCTAssertEqual(
            hal.lifecycleCalls,
            [
                .createIOProc(microphone),
                .start(microphone),
                .stop(microphone),
                .destroyIOProc(microphone),
                .createIOProc(otherMicrophone),
                .start(otherMicrophone)
            ]
        )
    }

    func testMicrophoneFailedStartThatReportsRunningIsStoppedBeforeItsIOProcIsDestroyed() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.startStatus = kAudioHardwareUnspecifiedError
        hal.isRunningRead = (noErr, 1)
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)
        let failed = expectation(description: "failed")
        events.onAppend = { event in
            if case .failed(self.microphone, _) = event {
                failed.fulfill()
            }
        }

        meter.start(deviceID: microphone)
        wait(for: [failed], timeout: timeout)

        XCTAssertEqual(
            hal.calls.filter { $0 == .readIsRunning(microphone) || !$0.isListenerCall },
            [
                .createIOProc(microphone),
                .start(microphone),
                .readIsRunning(microphone),
                .stop(microphone),
                .destroyIOProc(microphone)
            ]
        )
    }

    func testMicrophoneReleaseAtQuitRunsToCompletionThroughAWindow() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)
        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .started(microphone))

        hal.onCall = { call in
            if call == .stop(self.microphone) {
                generation.advance()
            }
        }
        let stops = LifecycleStopGroup()
        meter.stopAtQuit(in: stops)
        XCTAssertTrue(stops.wait(idleTimeout: timeout, ceiling: timeout).completed)
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .stop(microphone), .destroyIOProc(microphone)]
        )
    }

    func testSystemOutputStopInterruptedAfterAudioDeviceStopKeepsTheAggregateAndTheTap() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let built = hal.lifecycleCalls

        hal.onCall = { call in
            if call == .stop(self.aggregate) {
                generation.advance()
            }
        }
        let stopInterrupted = expectation(description: "stop interrupted")
        meter.onStopInterrupted = { stopInterrupted.fulfill() }
        meter.stop()
        wait(for: [stopInterrupted], timeout: timeout)
        XCTAssertEqual(hal.lifecycleCalls, built + [.stop(aggregate)])

        hal.onCall = nil
        meter.stop()
        meter.lifecycleQueue.sync {}
        XCTAssertEqual(
            hal.lifecycleCalls,
            built + [.stop(aggregate), .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)]
        )
    }

    func testSystemOutputStopInterruptedAfterTheIOProcDestroyKeepsTheTapWithItsAggregate() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let built = hal.lifecycleCalls

        hal.onCall = { call in
            if call == .destroyIOProc(self.aggregate) {
                generation.advance()
            }
        }
        let stopInterrupted = expectation(description: "stop interrupted")
        meter.onStopInterrupted = { stopInterrupted.fulfill() }
        meter.stop()
        wait(for: [stopInterrupted], timeout: timeout)
        XCTAssertEqual(
            hal.lifecycleCalls,
            built + [.stop(aggregate), .destroyIOProc(aggregate)],
            "the aggregate device and its tap stay inside the window"
        )

        // A rebuild after the window finishes the release before it builds.
        hal.onCall = nil
        let rebuilt = expectation(description: "rebuilt")
        meter.onStarted = { rebuilt.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [rebuilt], timeout: timeout)
        XCTAssertEqual(
            hal.lifecycleCalls,
            built + [.stop(aggregate), .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)] + built
        )
    }

    func testSystemOutputFailedStartThatReportsRunningIsStoppedBeforeDestroy() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.startStatus = kAudioHardwareUnspecifiedError
        hal.isRunningRead = (noErr, 1)
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let failed = expectation(description: "failed")
        meter.onError = { _ in failed.fulfill() }

        meter.start(deviceUID: "output")
        wait(for: [failed], timeout: timeout)

        XCTAssertEqual(
            hal.calls.filter { !$0.isListenerCall || $0 == .readIsRunning(aggregate) },
            [
                .createProcessTap,
                .createAggregate,
                .createIOProc(aggregate),
                .start(aggregate),
                .readIsRunning(aggregate),
                .stop(aggregate),
                .destroyIOProc(aggregate),
                .destroyAggregate(aggregate),
                .destroyProcessTap(tap)
            ]
        )
    }

    func testSystemOutputHandlesAreNotDestroyedTwiceAfterAFailedDestroy() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let built = hal.lifecycleCalls
        hal.setStatus(kAudioHardwareUnspecifiedError, for: .destroyAggregate)

        meter.stop()
        meter.lifecycleQueue.sync {}
        meter.stop()
        meter.lifecycleQueue.sync {}
        XCTAssertEqual(
            hal.lifecycleCalls,
            built + [.stop(aggregate), .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)]
        )
    }

    func testSystemOutputReleaseAtQuitRunsToCompletionThroughAWindow() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let built = hal.lifecycleCalls

        hal.onCall = { call in
            if call == .stop(self.aggregate) {
                generation.advance()
            }
        }
        let stops = LifecycleStopGroup()
        meter.stopAtQuit(in: stops)
        XCTAssertTrue(stops.wait(idleTimeout: timeout, ceiling: timeout).completed)
        XCTAssertEqual(
            hal.lifecycleCalls,
            built + [.stop(aggregate), .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)]
        )
    }

    // MARK: Quit

    func testQuitNamesTheSystemOutputPhaseItIsWaitingIn() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let unblock = DispatchSemaphore(value: 0)
        hal.onCall = { call in
            if call == .destroyAggregate(self.aggregate) {
                // coreaudiod not answering the destroy.
                unblock.wait()
            }
        }

        let stops = LifecycleStopGroup()
        meter.stopAtQuit(in: stops)
        let outcome = stops.wait(idleTimeout: 0.3, ceiling: timeout)
        unblock.signal()

        XCTAssertFalse(outcome.completed)
        XCTAssertLessThan(outcome.waited, timeout, "a call that does not return ends the wait at the idle bound")
        XCTAssertEqual(outcome.pending, [SystemOutputMeter.quitStopLabel: .destroyAggregate])
        XCTAssertEqual(outcome.pendingDescription, "system-output:destroy-aggregate")
        XCTAssertTrue(stops.wait(idleTimeout: timeout, ceiling: timeout).completed)
    }

    func testQuitNamesTheMicrophonePhaseItIsWaitingIn() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)
        meter.start(deviceID: microphone)
        waitForMicrophoneEvent(events, .started(microphone))
        let unblock = DispatchSemaphore(value: 0)
        hal.onCall = { call in
            if call == .stop(self.microphone) {
                unblock.wait()
            }
        }

        meter.closeLevelGateAtQuit()
        let stops = LifecycleStopGroup()
        meter.stopAtQuit(in: stops)
        let outcome = stops.wait(idleTimeout: 0.3, ceiling: timeout)
        unblock.signal()

        XCTAssertEqual(outcome.pending, [MicrophoneMeter.quitStopLabel: .stopIOProc])
        XCTAssertTrue(stops.wait(idleTimeout: timeout, ceiling: timeout).completed)
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .stop(microphone), .destroyIOProc(microphone)]
        )
    }

    func testASystemOutputBuildUnderWayWhenQuitClosesTheGatesNeverStartsIO() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let entered = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        hal.onCall = { call in
            if call == .createProcessTap {
                entered.signal()
                unblock.wait()
            }
        }
        meter.start(deviceUID: "output")
        XCTAssertEqual(entered.wait(timeout: .now() + timeout), .success, "the build reached its tap create")

        // Quit closes the gates, then runs its main-thread steps while the
        // build carries on; only after them is the meter's stop handed over.
        meter.closeLevelGateAtQuit()
        hal.onCall = nil
        unblock.signal()
        meter.lifecycleQueue.sync {}
        XCTAssertFalse(
            hal.lifecycleCalls.contains(.start(aggregate)),
            "the build does not reach AudioDeviceStart once the gates closed: \(hal.lifecycleCalls)"
        )

        let stops = LifecycleStopGroup()
        meter.stopAtQuit(in: stops)
        XCTAssertTrue(stops.wait(idleTimeout: timeout, ceiling: timeout).completed)
        XCTAssertFalse(hal.lifecycleCalls.contains(.start(aggregate)))
        XCTAssertEqual(
            Array(hal.lifecycleCalls.suffix(3)),
            [.destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)],
            "Quit's stop releases what the build created"
        )
    }

    func testQuitWaitsForAStopThatKeepsGettingAnswersPastTheIdleBound() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        // Each teardown call takes 0.2 s: four of them outlast the idle
        // bound, and each returns within it.
        hal.onCall = { call in
            switch call {
            case .stop, .destroyIOProc, .destroyAggregate, .destroyProcessTap:
                Thread.sleep(forTimeInterval: 0.2)
            default:
                break
            }
        }

        let stops = LifecycleStopGroup()
        meter.stopAtQuit(in: stops)
        let outcome = stops.wait(idleTimeout: 0.5, ceiling: timeout)

        XCTAssertTrue(outcome.completed)
        XCTAssertGreaterThanOrEqual(outcome.waited, 0.5)
    }

    // MARK: System playback meter invalidation

    func testSystemOutputStartListensToItsAggregateAndTheTappedOutput() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        _ = startedSystemOutputMeter(hal: hal, generation: generation)

        XCTAssertEqual(
            Set(hal.listenerSelectors(on: aggregate)),
            [
                kAudioDevicePropertyDeviceIsAlive,
                kAudioDevicePropertyStreamConfiguration,
                kAudioDevicePropertyIOStoppedAbnormally
            ]
        )
        XCTAssertEqual(
            hal.listenerSelectors(on: FakeHALLifecycleCalls.defaultOutputID),
            [kAudioDevicePropertyDeviceIsAlive]
        )
    }

    func testSystemOutputInvalidationReportsOnceAndMakesNoLifecycleCall() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let built = hal.lifecycleCalls
        let generationBefore = generation.current

        var reports = 0
        let invalidated = expectation(description: "invalidated")
        meter.onInvalidated = {
            reports += 1
            invalidated.fulfill()
        }
        hal.fireListener(deviceID: FakeHALLifecycleCalls.defaultOutputID, selector: kAudioDevicePropertyDeviceIsAlive)
        hal.fireListener(deviceID: aggregate, selector: kAudioDevicePropertyStreamConfiguration)
        wait(for: [invalidated], timeout: timeout)
        meter.lifecycleQueue.sync {}
        let settled = expectation(description: "main drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: timeout)

        XCTAssertEqual(reports, 1, "the first report closes the gate")
        XCTAssertEqual(hal.lifecycleCalls, built, "a listener never stops, destroys or rebuilds")
        XCTAssertEqual(
            generation.current,
            generationBefore + 2,
            "each notification advances the generation on the listener queue"
        )
    }

    func testSystemOutputListenerFiringAgainReportsTheChangeStillUnderWay() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let built = hal.lifecycleCalls

        var invalidations = 0
        var changes = 0
        meter.onInvalidated = { invalidations += 1 }
        meter.onChangeObserved = { changes += 1 }
        // A profile switch, then the switch back a little later.
        hal.fireListener(deviceID: aggregate, selector: kAudioDevicePropertyStreamConfiguration)
        drainMain()
        hal.fireListener(deviceID: aggregate, selector: kAudioDevicePropertyStreamConfiguration)
        hal.fireListener(deviceID: aggregate, selector: kAudioDevicePropertyIOStoppedAbnormally)
        drainMain()

        XCTAssertEqual(invalidations, 1, "one rebuild is owed")
        XCTAssertEqual(changes, 2, "every later notification extends the window")
        XCTAssertEqual(hal.lifecycleCalls, built)

        // A released build's listeners report nothing and advance nothing.
        meter.stop()
        meter.lifecycleQueue.sync {}
        let afterRelease = generation.current
        meter.onInvalidated = { XCTFail("a released build reports nothing") }
        meter.onChangeObserved = { XCTFail("a released build reports nothing") }
        hal.fireListener(deviceID: aggregate, selector: kAudioDevicePropertyDeviceIsAlive)
        drainMain()
        XCTAssertEqual(generation.current, afterRelease)
    }

    func testSystemOutputListenerFiringDuringItsOwnBuildAbandonsTheBuild() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let firstAggregate = aggregate
        hal.onCall = { call in
            if call == .createIOProc(firstAggregate) {
                hal.fireListener(deviceID: firstAggregate, selector: kAudioDevicePropertyStreamConfiguration)
            }
        }
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let interrupted = expectation(description: "interrupted")
        meter.onInterrupted = { interrupted.fulfill() }
        meter.onStarted = { XCTFail("started although its device reconfigured during the build") }

        meter.start(deviceUID: "output")
        wait(for: [interrupted], timeout: timeout)

        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createProcessTap, .createAggregate, .createIOProc(aggregate)],
            "AudioDeviceStart is not called, and nothing is destroyed inside the window"
        )
    }

    func testSystemOutputReleaseRemovesItsListenersBeforeTheStop() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let before = hal.calls.count

        meter.stop()
        meter.lifecycleQueue.sync {}

        let release = Array(hal.calls.dropFirst(before))
        XCTAssertEqual(
            release,
            [
                .removePropertyListener(aggregate),
                .removePropertyListener(aggregate),
                .removePropertyListener(aggregate),
                .removePropertyListener(FakeHALLifecycleCalls.defaultOutputID),
                .stop(aggregate),
                .destroyIOProc(aggregate),
                .destroyAggregate(aggregate),
                .destroyProcessTap(tap)
            ]
        )
        XCTAssertTrue(hal.listenerSelectors(on: aggregate).isEmpty)
        XCTAssertTrue(hal.listenerSelectors(on: FakeHALLifecycleCalls.defaultOutputID).isEmpty)
    }

    func testSystemOutputStopInterruptedBeforeTheListenerRemovalKeepsEverything() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let before = hal.calls.count

        meter.lifecycleQueue.suspend()
        let stopInterrupted = expectation(description: "stop interrupted")
        meter.onStopInterrupted = { stopInterrupted.fulfill() }
        meter.stop()
        generation.advance()
        meter.lifecycleQueue.resume()
        wait(for: [stopInterrupted], timeout: timeout)

        XCTAssertEqual(hal.calls.count, before, "no listener removal and no lifecycle call inside the window")
        XCTAssertEqual(hal.listenerSelectors(on: aggregate).count, 3)
    }

    func testSystemOutputForgetDropsItsListenersWithoutAHALCall() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let meter = startedSystemOutputMeter(hal: hal, generation: generation)
        let before = hal.calls.count
        meter.onInvalidated = { XCTFail("a forgotten meter reports nothing") }

        meter.forgetAfterServiceRestart()
        meter.lifecycleQueue.sync {}
        hal.fireListener(deviceID: aggregate, selector: kAudioDevicePropertyDeviceIsAlive)
        let settled = expectation(description: "main drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: timeout)

        XCTAssertEqual(hal.calls.count, before)

        // The rebuild after the window has nothing to remove or destroy first.
        let rebuilt = expectation(description: "rebuilt")
        meter.onStarted = { rebuilt.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [rebuilt], timeout: timeout)
        XCTAssertFalse(hal.calls.dropFirst(before).contains { call in
            if case .removePropertyListener = call { return true }
            if case .destroyAggregate = call { return true }
            return false
        })
    }

    // MARK: Helpers

    private func drainMain() {
        let settled = expectation(description: "main drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: timeout)
    }

    private func startedSystemOutputMeter(
        hal: FakeHALLifecycleCalls,
        generation: LifecycleHoldGeneration
    ) -> SystemOutputMeter {
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let started = expectation(description: "started")
        meter.onStarted = { started.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [started], timeout: timeout)
        meter.onStarted = nil
        return meter
    }

    /// Microphone meter events as the main thread received them.
    private final class EventLog {
        var values: [MicrophoneMeter.Event] = []
        var onAppend: ((MicrophoneMeter.Event) -> Void)?
    }

    private func recordEvents(of meter: MicrophoneMeter) -> EventLog {
        let log = EventLog()
        meter.onEvent = { event in
            log.values.append(event)
            log.onAppend?(event)
        }
        return log
    }

    private func waitForMicrophoneEvent(_ log: EventLog, _ expected: MicrophoneMeter.Event) {
        guard !log.values.contains(expected) else {
            return
        }
        let arrived = expectation(description: "\(expected)")
        log.onAppend = { event in
            if event == expected {
                arrived.fulfill()
            }
        }
        wait(for: [arrived], timeout: timeout)
        log.onAppend = nil
    }

    private func stopAndWait(_ meter: MicrophoneMeter) -> MicrophoneMeter.StopOutcome? {
        let done = expectation(description: "stop")
        var outcome: MicrophoneMeter.StopOutcome?
        meter.stop { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        return outcome
    }
}
