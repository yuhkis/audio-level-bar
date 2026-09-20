import AudioLevelBarCore
import CoreAudio
import Dispatch
import XCTest
@testable import AudioLevelBar

/// What the destroys an evaluation makes on the main thread do when a
/// listener has advanced the quiet window's generation since that evaluation
/// read its admission: the publication's owed teardown, the retry of a
/// switched-off teardown, and the launch cleanup. Through the harness, so
/// nothing reaches coreaudiod.
///
/// Each carries the generation the evaluation saw and compares it immediately
/// before each destroy. Held back, nothing more is destroyed inside that
/// window, the work stays owed, and the release after the window finishes it.
final class AudioStateOwedTeardownTests: XCTestCase {
    private let microphone = AudioStateHarness.builtInMicrophone
    private let aggregate = AudioStateHarness.publishedAggregate
    private let tap = AudioStateHarness.publishedTap
    private let publishedUID = PublicProcessedMicrophoneDevice.aggregateDeviceUID

    /// A default-input listener fires once, on the main thread, right after
    /// the next `quiet-window release` line: after the evaluation has read
    /// its admission and before any step it issues, as the listener queue
    /// would advance the generation while the main thread evaluates.
    private func advanceTheGenerationInsideTheNextRelease(_ harness: AudioStateHarness) {
        var fired = false
        harness.lines.onLine = { [unowned harness] line in
            guard line.hasPrefix("quiet-window release "), !fired else {
                return
            }
            fired = true
            harness.fireSystemNotification(.defaultInput)
        }
    }

    /// A default-input listener fires once inside the first call equal to
    /// `call`, on the thread that makes it, as the listener queue would
    /// while that call waits in coreaudiod.
    private func advanceTheGeneration(_ harness: AudioStateHarness, inside call: FakeHALLifecycleCalls.Call) {
        var fired = false
        harness.holds.onEnter = { [unowned harness] point in
            guard point == .hal(call), !fired else {
                return
            }
            fired = true
            harness.fireSystemNotification(.defaultInput)
        }
    }

    private func passWindow(_ harness: AudioStateHarness) {
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
    }

    private func generation(of line: String?) -> String? {
        line.flatMap { AudioStateHarness.field("gen", of: $0) }
    }

    private func lastOperation(of publisher: FakePublisherEngine) -> FakePublisherEngine.Call? {
        publisher.calls.last { $0 != .readBoundOutput }
    }

    /// The calls on the published tap and aggregate device, and on an
    /// earlier run's, made after the first `count` calls.
    private func destroys(_ harness: AudioStateHarness, after count: Int) -> [FakeHALLifecycleCalls.Call] {
        harness.lifecycleCalls(after: count).filter { call in
            switch call {
            case .destroyAggregate, .destroyProcessTap:
                return true
            default:
                return false
            }
        }
    }

    /// The begin lines a quiet window holds, judged as the gate's criterion
    /// 10 judges them: a generation below the highest held or advanced so
    /// far, or equal to it before that generation's release. `gen=-` lines
    /// are not judged.
    private func beginLinesInsideAWindow(_ harness: AudioStateHarness) -> [String] {
        var highest = -1
        var released = Set<Int>()
        var hits: [String] = []
        for line in harness.lines.values {
            let generation = AudioStateHarness.field("gen", of: line).flatMap { Int($0) }
            if line.hasPrefix("quiet-window hold ") || line.hasPrefix("quiet-window advance ") {
                highest = max(highest, generation ?? highest)
            } else if line.hasPrefix("quiet-window release ") {
                generation.map { released.insert($0) }
            } else if
                line.contains("-begin "),
                let generation,
                generation < highest || (generation == highest && !released.contains(generation))
            {
                hits.append(line)
            }
        }
        return hits
    }

    // MARK: The owed teardown

    /// Published and idle, with no consuming app and no engines: a change
    /// arms the window, and the feature is switched off inside it, so the
    /// release owes the publication's teardown.
    private func switchedOffInsideAWindow(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioStateHarness {
        let harness = AudioStateHarness(processedMicrophone: true)
        harness.launchAndPublish(file: file, line: line)
        harness.fireSystemNotification(.defaultInput)
        harness.settle()
        harness.state.setProcessedMicrophoneEnabled(false)
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled, file: file, line: line)
        return harness
    }

    func testAnOwedTeardownIssuedAfterAListenerAdvancedTheGenerationDestroysNothingUntilTheNextRelease() {
        let harness = switchedOffInsideAWindow()
        defer { harness.tearDown() }
        let before = harness.hal.calls.count
        advanceTheGenerationInsideTheNextRelease(harness)

        passWindow(harness)

        let issuedIn = generation(of: harness.lines(withPrefix: "quiet-window release ").last)
        XCTAssertNotNil(issuedIn)
        XCTAssertEqual(
            Array(harness.hal.calls.dropFirst(before)),
            [],
            "neither the aggregate device nor the tap is destroyed inside the window, and in use is not read either"
        )
        let interrupts = harness.lines(withPrefix: "processed-microphone-aggregate interrupt-stop ")
        XCTAssertEqual(interrupts.count, 1, "\(interrupts)")
        XCTAssertEqual(generation(of: interrupts.first), issuedIn, "the generation the evaluation saw")
        XCTAssertEqual(interrupts.first.flatMap { AudioStateHarness.field("reason", of: $0) }, "before-destroy")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-aggregate destroy").isEmpty)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-tap destroy").isEmpty)

        // Nothing more while the window the listener's change armed holds.
        harness.advance(by: 1)
        harness.poll()
        XCTAssertEqual(destroys(harness, after: before), [])

        passWindow(harness)

        XCTAssertEqual(
            destroys(harness, after: before),
            [.destroyAggregate(aggregate), .destroyProcessTap(tap)],
            "the release after the window carries the owed teardown out"
        )
        XCTAssertEqual(
            generation(of: harness.lines(withPrefix: "processed-microphone-aggregate destroy-begin ").last),
            generation(of: harness.lines(withPrefix: "quiet-window release ").last),
            "with the generation of the release that issued it"
        )
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)

        // The teardown is settled: nothing more at later releases.
        let settled = harness.hal.calls.count
        for _ in 0..<8 {
            harness.advance(by: 0.25)
            harness.poll()
        }
        XCTAssertEqual(destroys(harness, after: settled), [])
    }

    func testAWindowThatArmsInsideTheAggregateDevicesDestroyHoldsTheTapsDestroyBackForTheNextRelease() {
        let harness = switchedOffInsideAWindow()
        defer { harness.tearDown() }
        let before = harness.hal.calls.count
        advanceTheGeneration(harness, inside: .destroyAggregate(aggregate))

        passWindow(harness)

        XCTAssertEqual(
            destroys(harness, after: before),
            [.destroyAggregate(aggregate)],
            "the tap's destroy, up to half a second after the device's, is held back"
        )
        let interrupts = harness.lines(withPrefix: "processed-microphone-tap interrupt-stop ")
        XCTAssertEqual(interrupts.count, 1, "\(interrupts)")
        XCTAssertEqual(interrupts.first.flatMap { AudioStateHarness.field("reason", of: $0) }, "before-destroy")
        XCTAssertEqual(
            generation(of: interrupts.first),
            generation(of: harness.lines(withPrefix: "processed-microphone-aggregate destroy ").last),
            "the generation the teardown was issued in"
        )
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)

        passWindow(harness)

        XCTAssertEqual(
            destroys(harness, after: before),
            [.destroyAggregate(aggregate), .destroyProcessTap(tap)],
            "the release after the window destroys the tap that was kept"
        )
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)

        let settled = harness.hal.calls.count
        for _ in 0..<8 {
            harness.advance(by: 0.25)
            harness.poll()
        }
        XCTAssertEqual(harness.lifecycleCalls(after: settled), [], "and the teardown is settled")
    }

    func testAWindowThatArmsWhileTheEnginesStopHoldsThePublicationsDestroysBack() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
        guard let publisher = harness.publisherEngines.engines.last else {
            return XCTFail("no publisher was built")
        }
        // The listener fires while the publisher's stop is on its way.
        var fired = false
        publisher.onCall = { [unowned harness] call in
            guard call == .stop, !fired else {
                return
            }
            fired = true
            harness.fireSystemNotification(.defaultInput)
        }
        // The consuming app lets go, and the feature is switched off while
        // the engines still run out their grace period: no window holds, so
        // the teardown is issued at once.
        harness.setPublishedDeviceInUse(false)
        harness.settle()
        let before = harness.hal.calls.count

        // Keep capture teardown queued until the publisher's stop has fired
        // the notification. Otherwise its generation check and begin line
        // can straddle that notification on a different queue, so this
        // publication-teardown test depends on thread scheduling.
        let captureMayStop = DispatchSemaphore(value: 0)
        harness.state.lifecycleQueuesForTesting.processedMicrophoneCapture.async {
            captureMayStop.wait()
        }
        harness.state.setProcessedMicrophoneEnabled(false)
        captureMayStop.signal()
        harness.settle()

        XCTAssertTrue(fired, "the notification ran inside the publisher's stop")
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-capture-ioproc interrupt-stop ").count,
            1,
            "the queued capture release is held by the same notification"
        )
        XCTAssertEqual(lastOperation(of: publisher), .stop, "the stop was issued before the change began")
        XCTAssertEqual(
            destroys(harness, after: before),
            [],
            "the destroys that follow it are not made inside the window that armed meanwhile"
        )
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-aggregate interrupt-stop ").count, 1)

        passWindow(harness)

        XCTAssertEqual(destroys(harness, after: before), [.destroyAggregate(aggregate), .destroyProcessTap(tap)])
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)
    }

    // MARK: The retry of a switched-off teardown

    func testARetryOfASwitchedOffTeardownDoesNotDestroyAnEarlierRunsDeviceInsideAWindow() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launchAndRelease()
        let earlierDevice: AudioObjectID = 900
        // An earlier run's device is listed, and a listener fires, while the
        // retry reads the device lists on the main thread, after its own
        // withdrawal found nothing and before it removes what is left over.
        var fired = false
        harness.system.onMainThreadDeviceListRead = { [unowned harness, publishedUID] in
            guard !fired else {
                return
            }
            fired = true
            harness.hal.listedDevices = [(earlierDevice, publishedUID)]
            harness.fireSystemNotification(.defaultInput)
        }
        let before = harness.hal.calls.count

        harness.state.retryProcessedMicrophone()
        harness.settle()

        XCTAssertEqual(destroys(harness, after: before), [], "nothing is destroyed inside the window")
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-aggregate interrupt-stop id=\(earlierDevice) ").count,
            1
        )

        passWindow(harness)

        XCTAssertEqual(
            destroys(harness, after: before),
            [.destroyAggregate(earlierDevice)],
            "the retry is carried out by the release after the window"
        )
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
    }

    // MARK: The launch cleanup

    func testTheLaunchCleanupDoesNotDestroyAnEarlierRunsDeviceAfterAListenerAdvancedTheGeneration() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        let earlierDevice: AudioObjectID = 900
        harness.hal.listedDevices = [(earlierDevice, publishedUID)]
        harness.launch()
        advanceTheGenerationInsideTheNextRelease(harness)

        passWindow(harness)

        XCTAssertEqual(harness.hal.lifecycleCalls, [], "neither the destroy nor any start: the cleanup is still owed")
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-aggregate interrupt-stop id=\(earlierDevice) ").count,
            1
        )
        XCTAssertEqual(harness.holdReasons.last, "hal-notification")

        passWindow(harness)

        XCTAssertEqual(
            harness.hal.lifecycleCalls,
            [.destroyAggregate(earlierDevice)],
            "the release after the window runs the cleanup, and issues nothing more"
        )
        XCTAssertEqual(harness.holdReasons.last, "launch-cleanup")

        passWindow(harness)
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.createIOProc(microphone)), "starts follow the cleanup")
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
    }

    func testTheLaunchCleanupHoldsTheRestOfItsTapsBackWhenAWindowArmsInsideADestroy() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.earlierRunTaps.strand(301, uid: "earlier-tap-1")
        harness.earlierRunTaps.strand(302, uid: "earlier-tap-2")
        harness.launch()
        advanceTheGeneration(harness, inside: .destroyProcessTap(301))

        passWindow(harness)

        XCTAssertEqual(
            harness.hal.lifecycleCalls,
            [.destroyProcessTap(301)],
            "the second tap is not destroyed inside the window, and nothing starts: the cleanup is owed again"
        )
        let interrupts = harness.lines(withPrefix: "reclaimed-tap interrupt-stop id=302 ")
        XCTAssertEqual(interrupts.count, 1, "\(harness.lines(withPrefix: "reclaimed-tap "))")
        XCTAssertEqual(interrupts.first.flatMap { AudioStateHarness.field("reason", of: $0) }, "launch")
        XCTAssertEqual(
            generation(of: interrupts.first),
            generation(of: harness.lines(withPrefix: "reclaimed-tap destroy id=301 ").last),
            "the generation the cleanup was issued in"
        )

        passWindow(harness)

        let calls = harness.hal.lifecycleCalls
        XCTAssertEqual(Array(calls.prefix(2)), [.destroyProcessTap(301), .destroyProcessTap(302)])
        XCTAssertEqual(calls.filter { $0 == .destroyProcessTap(301) }.count, 1, "what is gone is not found again")
        XCTAssertTrue(calls.contains(.createIOProc(microphone)), "and starts follow the cleanup: \(calls)")
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
    }
}
