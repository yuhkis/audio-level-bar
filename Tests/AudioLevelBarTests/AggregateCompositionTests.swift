import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// What the microphone meter and the processed microphone's capture do with
/// an aggregate device, through a fake HAL that never reaches coreaudiod: the
/// transport read again once the listeners are in place, before
/// `AudioDeviceStart`, and the listeners on both sub-device lists.
final class AggregateCompositionTests: XCTestCase {
    private let timeout: TimeInterval = 5
    private let aggregate: AudioDeviceID = 41

    private let wired = AudioDeviceTransportInfo(
        transport: .aggregate,
        activeSubDeviceTransports: [.builtIn],
        fullSubDeviceTransports: [.builtIn]
    )
    /// The composition edited to name a headset that is not active.
    private let inactiveHeadset = AudioDeviceTransportInfo(
        transport: .aggregate,
        activeSubDeviceTransports: [.builtIn],
        fullSubDeviceTransports: [.builtIn, .bluetooth]
    )
    /// The headset active in the aggregate.
    private let activeHeadset = AudioDeviceTransportInfo(
        transport: .aggregate,
        activeSubDeviceTransports: [.builtIn, .bluetooth],
        fullSubDeviceTransports: [.builtIn, .bluetooth]
    )

    override func tearDown() {
        HALLifecycleLog.observer = nil
        super.tearDown()
    }

    // MARK: Microphone meter

    func testMeterRefusesAnAggregateWithAnAbsentMemberWithoutCreatingAnything() {
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(
            AudioDeviceTransportInfo(
                transport: .aggregate,
                activeSubDeviceTransports: [.builtIn],
                fullSubDeviceTransports: [.builtIn, nil]
            ),
            for: aggregate
        )
        let lines = LineRecorder(prefix: "microphone-ioproc")
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let events = recordEvents(of: meter)

        meter.start(deviceID: aggregate)
        waitFor(events, .refused(aggregate, .aggregateWithUnresolvedMember))

        XCTAssertEqual(hal.calls, [])
        XCTAssertTrue(
            lines.values.contains { $0.hasPrefix("microphone-ioproc refuse id=41 transport=aggregate[builtIn|builtIn,?]") },
            "\(lines.values)"
        )
    }

    func testMeterSecondReadShowingBluetoothNeverStarts() {
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(wired, for: aggregate)
        changeTransportAtSecondRead(hal, to: inactiveHeadset)
        let lines = LineRecorder(prefix: "microphone-ioproc")
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let events = recordEvents(of: meter)

        meter.start(deviceID: aggregate)
        waitFor(events, .refused(aggregate, .aggregateWithBluetoothMember))

        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(aggregate), .destroyIOProc(aggregate)],
            "created before the second read, released without a start"
        )
        XCTAssertTrue(hal.listenerSelectors(on: aggregate).isEmpty, "its listeners are removed")
        XCTAssertTrue(
            lines.values.contains { $0.hasPrefix("microphone-ioproc refuse id=41 transport=aggregate[builtIn|builtIn,bluetooth]") },
            "\(lines.values)"
        )
        XCTAssertFalse(lines.values.contains { $0.contains("start") })
    }

    func testMeterSecondReadRefusalInsideAWindowReleasesNothingInsideIt() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(wired, for: aggregate)
        changeTransportAtSecondRead(hal, to: activeHeadset) {
            generation.advance()
        }
        let lines = LineRecorder(prefix: "microphone-ioproc")
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)

        meter.start(deviceID: aggregate)
        waitFor(events, .interrupted(aggregate))

        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(aggregate)])
        let operations = lines.values.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        XCTAssertEqual(
            Array(operations.suffix(2)),
            ["microphone-ioproc refuse", "microphone-ioproc interrupt"],
            "the refusal is logged, then the interruption"
        )

        // After the window, the owner's stop releases what the start created.
        hal.onRead = nil
        XCTAssertEqual(stopAndWait(meter), .stopped)
        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(aggregate), .destroyIOProc(aggregate)])
    }

    func testMeterListensToBothSubDeviceListsOfAnOpenAggregate() {
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(wired, for: aggregate)
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let events = recordEvents(of: meter)

        meter.start(deviceID: aggregate)
        waitFor(events, .started(aggregate))

        let selectors = hal.listenerSelectors(on: aggregate)
        XCTAssertTrue(selectors.contains(kAudioAggregateDevicePropertyActiveSubDeviceList))
        XCTAssertTrue(selectors.contains(kAudioAggregateDevicePropertyFullSubDeviceList))
    }

    func testMeterDoesNotListenToSubDeviceListsOfADirectDevice() {
        let hal = FakeHALLifecycleCalls()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let events = recordEvents(of: meter)

        meter.start(deviceID: aggregate)
        waitFor(events, .started(aggregate))

        let selectors = hal.listenerSelectors(on: aggregate)
        XCTAssertFalse(selectors.contains(kAudioAggregateDevicePropertyActiveSubDeviceList))
        XCTAssertFalse(selectors.contains(kAudioAggregateDevicePropertyFullSubDeviceList))
    }

    func testMeterFullCompositionGainingABluetoothMemberOnlyInvalidates() {
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(wired, for: aggregate)
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let events = recordEvents(of: meter)
        meter.start(deviceID: aggregate)
        waitFor(events, .started(aggregate))
        let callsWhileRunning = hal.calls

        hal.setTransportInfo(inactiveHeadset, for: aggregate)
        hal.fireListener(deviceID: aggregate, selector: kAudioAggregateDevicePropertyFullSubDeviceList)
        waitFor(events, .invalidated(aggregate))
        meter.lifecycleQueue.sync {}

        XCTAssertEqual(hal.calls, callsWhileRunning, "left to the owner's evaluation after the window")
    }

    func testMeterActiveBluetoothMemberStopsAtOnceAsTheLastResort() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(wired, for: aggregate)
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let events = recordEvents(of: meter)
        meter.start(deviceID: aggregate)
        waitFor(events, .started(aggregate))
        let lines = LineRecorder(prefix: "microphone-ioproc")

        // A window armed by the headset's arrival does not hold this stop.
        generation.advance()
        hal.setTransportInfo(activeHeadset, for: aggregate)
        hal.fireListener(deviceID: aggregate, selector: kAudioAggregateDevicePropertyActiveSubDeviceList)
        meter.lifecycleQueue.sync {}

        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(aggregate), .start(aggregate), .stop(aggregate), .destroyIOProc(aggregate)]
        )
        let reasoned = lines.values.filter { $0.contains("reason=bluetooth-sub-device") }
        XCTAssertEqual(
            reasoned.map { $0.split(separator: " ").prefix(2).joined(separator: " ") },
            [
                "microphone-ioproc refuse",
                "microphone-ioproc stop-begin",
                "microphone-ioproc stop",
                "microphone-ioproc destroy-begin",
                "microphone-ioproc destroy"
            ],
            "\(lines.values)"
        )
        XCTAssertTrue(reasoned.allSatisfy { $0.contains("gen=-") }, "not issued in any generation")
    }

    // MARK: Processed microphone capture

    func testCaptureListensToBothSubDeviceListsAndReadsAgainBeforeTheStart() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(wired, for: aggregate)
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        let session = prepare(capture, generation: generation)

        let selectors = hal.listenerSelectors(on: aggregate)
        XCTAssertTrue(selectors.contains(kAudioAggregateDevicePropertyActiveSubDeviceList))
        XCTAssertTrue(selectors.contains(kAudioAggregateDevicePropertyFullSubDeviceList))

        // The composition was edited while the publisher started.
        hal.setTransportInfo(inactiveHeadset, for: aggregate)
        let token = generation.current
        let outcome = capture.queue.sync { capture.startIO(session: session, holdToken: token) }

        guard case .refused(.aggregateWithBluetoothMember)? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(aggregate), .destroyIOProc(aggregate)])
    }

    func testCaptureFullCompositionChangeOnlyInvalidates() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(wired, for: aggregate)
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        let invalidated = expectation(description: "invalidated")
        let session = prepare(capture, generation: generation) { invalidated.fulfill() }
        let token = generation.current
        guard case .started? = capture.queue.sync(execute: { capture.startIO(session: session, holdToken: token) }) else {
            return XCTFail("not started")
        }
        let callsWhileRunning = hal.calls

        hal.setTransportInfo(inactiveHeadset, for: aggregate)
        hal.fireListener(deviceID: aggregate, selector: kAudioAggregateDevicePropertyFullSubDeviceList)
        wait(for: [invalidated], timeout: timeout)
        capture.queue.sync {}

        XCTAssertEqual(hal.calls, callsWhileRunning)
    }

    // MARK: Helpers

    /// Makes the second `transportInfo` read of the aggregate, and every read
    /// after it, return `info`, running `alsoAtTheRead` inside that read.
    private func changeTransportAtSecondRead(
        _ hal: FakeHALLifecycleCalls,
        to info: AudioDeviceTransportInfo,
        alsoAtTheRead: @escaping () -> Void = {}
    ) {
        let target = aggregate
        let reads = ReadCounter()
        hal.onRead = { [weak hal] read in
            guard read == .transportInfo(target), reads.next() == 2 else {
                return
            }
            hal?.setTransportInfo(info, for: target)
            alsoAtTheRead()
        }
    }

    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

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

    private func waitFor(_ log: EventLog, _ expected: MicrophoneMeter.Event) {
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

    private func prepare(
        _ capture: ProcessedMicrophoneDeviceCapture,
        generation: LifecycleHoldGeneration,
        onInvalidated: @escaping () -> Void = {}
    ) -> UUID {
        let session = UUID()
        capture.begin(session: session)
        let token = generation.current
        let device = aggregate
        let outcome = capture.queue.sync {
            capture.prepare(
                deviceID: device,
                session: session,
                gainScalar: ProcessedMicrophoneAtomicFloat(1),
                webRTCLevel: nil,
                holdToken: token,
                onInvalidated: onInvalidated
            )
        }
        guard case .prepared? = outcome else {
            XCTFail("not prepared: \(String(describing: outcome))")
            return session
        }
        return session
    }
}
