import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// What the processed microphone's stops, and the release of a start whose
/// publisher build failed, do when a listener has advanced the quiet
/// window's generation before the main thread hears of the change, through
/// the harness: nothing reaches coreaudiod.
///
/// The stops carry the generation the evaluation that issued them saw, so
/// they end before their first call inside that window, the engines' stops
/// on the main thread included, and the release after the window stops what
/// they left.
final class AudioStateEngineStopTests: XCTestCase {
    private let microphone = AudioStateHarness.builtInMicrophone
    private let aggregate = AudioStateHarness.publishedAggregate
    private let tap = AudioStateHarness.publishedTap

    /// Launches with `mode`, publishes, and has a consuming app open the
    /// published device, so the engines run.
    private func runningHarness(
        mode: MicrophoneProcessingMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioStateHarness {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: mode)
        harness.launchAndPublish(file: file, line: line)
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .active, file: file, line: line)
        return harness
    }

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

    /// The stops and destroys of an IOProc on the microphone made after the
    /// first `count` calls. The capture's release runs on its own queue, next
    /// to the meter's start on the input it gets back, so only their order
    /// among themselves is fixed.
    private func captureReleases(_ harness: AudioStateHarness, after count: Int) -> [FakeHALLifecycleCalls.Call] {
        harness.lifecycleCalls(after: count).filter { $0 == .stop(microphone) || $0 == .destroyIOProc(microphone) }
    }

    /// The calls on the published tap and aggregate device made after the
    /// first `count` calls.
    private func publicationCalls(_ harness: AudioStateHarness, after count: Int) -> [FakeHALLifecycleCalls.Call] {
        harness.lifecycleCalls(after: count).filter {
            [.createProcessTap, .createAggregate, .destroyAggregate(aggregate), .destroyProcessTap(tap)].contains($0)
        }
    }

    // MARK: A stop issued under a generation the main thread has not seen

    func testAStopIssuedAfterAListenerAdvancedTheGenerationStopsNothingUntilTheNextRelease() {
        let harness = runningHarness(mode: .off)
        defer { harness.tearDown() }
        guard let publisher = harness.publisherEngines.engines.last else {
            return XCTFail("no publisher was built")
        }
        // A change arms the window, and the feature is switched off inside
        // it while the consuming app keeps the device open: the release
        // stops the engines and keeps the publication.
        harness.fireSystemNotification(.defaultInput)
        harness.settle()
        harness.state.setProcessedMicrophoneEnabled(false)
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .awaitingRelease)
        let before = harness.hal.calls.count
        advanceTheGenerationInsideTheNextRelease(harness)

        passWindow(harness)

        let issuedIn = generation(of: harness.lines(withPrefix: "quiet-window release ").last)
        XCTAssertNotNil(issuedIn)
        XCTAssertEqual(
            Array(harness.hal.calls.dropFirst(before)),
            [],
            "neither the IOProc's listeners, its stop nor its destroy reach the HAL inside the window"
        )
        XCTAssertEqual(lastOperation(of: publisher), .start, "the publisher is not stopped inside the window")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-capture-ioproc stop").isEmpty)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-capture-ioproc destroy").isEmpty)
        let publisherInterrupt = harness.lines(withPrefix: "processed-microphone-publisher-engine interrupt-stop ")
        XCTAssertEqual(publisherInterrupt.count, 1, "\(publisherInterrupt)")
        XCTAssertEqual(generation(of: publisherInterrupt.first), issuedIn, "the generation the evaluation saw")
        XCTAssertEqual(
            publisherInterrupt.first.flatMap { AudioStateHarness.field("id", of: $0) },
            "\(AudioStateHarness.speakers)"
        )
        let captureInterrupt = harness.lines(withPrefix: "processed-microphone-capture-ioproc interrupt-stop ")
        XCTAssertEqual(captureInterrupt.count, 1, "\(captureInterrupt)")
        XCTAssertEqual(generation(of: captureInterrupt.first), issuedIn)
        XCTAssertTrue(
            harness.state.processedMicrophoneEngineForTesting.retiredEnginesForTesting.isEmpty,
            "nothing is retired, so nothing can be freed inside the window"
        )
        XCTAssertTrue(harness.state.processedMicrophoneEngineForTesting.isRunning, "what was kept counts as running")
        XCTAssertTrue(harness.state.processedMicrophoneEngineForTesting.needsRestart)

        // Nothing more while the window the listener's change armed holds.
        harness.advance(by: 1)
        harness.poll()
        XCTAssertEqual(Array(harness.hal.calls.dropFirst(before)), [])
        XCTAssertEqual(lastOperation(of: publisher), .start)

        passWindow(harness)

        XCTAssertEqual(
            captureReleases(harness, after: before),
            [.stop(microphone), .destroyIOProc(microphone)],
            "the release after the window stops and destroys the IOProc"
        )
        XCTAssertEqual(publicationCalls(harness, after: before), [], "and keeps the publication, which is in use")
        XCTAssertEqual(lastOperation(of: publisher), .stop, "and stops the publisher")
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-publisher-engine stop ").count, 1)
        XCTAssertFalse(harness.state.processedMicrophoneEngineForTesting.isRunning, "nothing is left running")
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .awaitingRelease)
    }

    func testAnAppleVoiceProcessingStopIsHeldBackTheSameWay() {
        let harness = runningHarness(mode: .apple)
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.last,
            let publisher = harness.publisherEngines.engines.last
        else {
            return XCTFail("the engines were not built")
        }
        harness.fireSystemNotification(.defaultInput)
        harness.settle()
        harness.state.setProcessedMicrophoneEnabled(false)
        harness.settle()
        advanceTheGenerationInsideTheNextRelease(harness)

        passWindow(harness)

        let issuedIn = generation(of: harness.lines(withPrefix: "quiet-window release ").last)
        XCTAssertEqual(capture.calls.last, .start, "the capture engine is neither stopped nor untapped inside the window")
        XCTAssertEqual(lastOperation(of: publisher), .start)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop").isEmpty)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)
        let interrupts = harness.lines.values.filter { $0.contains("-engine interrupt-stop ") }
        XCTAssertEqual(interrupts.count, 2, "one line for each engine kept: \(interrupts)")
        XCTAssertEqual(interrupts.first?.hasPrefix("processed-microphone-voice-processing-engine "), true)
        XCTAssertEqual(interrupts.first.flatMap { AudioStateHarness.field("id", of: $0) }, "\(microphone)")
        for line in interrupts {
            XCTAssertEqual(generation(of: line), issuedIn, line)
        }

        passWindow(harness)

        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the release after the window stops it")
        XCTAssertEqual(lastOperation(of: publisher), .stop)
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop ").count, 1)
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-publisher-engine stop ").count, 1)
        XCTAssertFalse(harness.state.processedMicrophoneEngineForTesting.isRunning)
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
    }

    func testAWindowThatArmsInsideTheCaptureEnginesStopHoldsThePublishersStopBack() {
        let harness = runningHarness(mode: .apple)
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.last,
            let publisher = harness.publisherEngines.engines.last
        else {
            return XCTFail("the engines were not built")
        }
        harness.fireSystemNotification(.defaultInput)
        harness.settle()
        harness.state.setProcessedMicrophoneEnabled(false)
        harness.settle()
        // Apple voice processing has two engine stops behind the release.
        // The capture engine's waits in coreaudiod, and a listener advances
        // the generation before it returns.
        var fired = false
        let noted = capture.onCall
        capture.onCall = { [unowned harness] call in
            noted?(call)
            if call == .stop, !fired {
                fired = true
                harness.fireSystemNotification(.defaultInput)
            }
        }
        let before = harness.hal.calls.count

        passWindow(harness)

        let issuedIn = generation(of: harness.lines(withPrefix: "quiet-window release ").last)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the stop already issued runs to its end")
        XCTAssertEqual(lastOperation(of: publisher), .start, "the publisher's stop is not made inside the window")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)
        let interrupts = harness.lines.values.filter { $0.contains("-engine interrupt-stop ") }
        XCTAssertEqual(interrupts.count, 1, "\(interrupts)")
        XCTAssertEqual(interrupts.first?.hasPrefix("processed-microphone-publisher-engine "), true)
        XCTAssertEqual(generation(of: interrupts.first), issuedIn)
        XCTAssertEqual(
            publicationCalls(harness, after: before),
            [],
            "and the muted tap is not withdrawn under a publisher that still renders"
        )
        XCTAssertTrue(harness.state.processedMicrophoneEngineForTesting.isRunning, "a restart is owed")

        passWindow(harness)

        XCTAssertEqual(lastOperation(of: publisher), .stop, "the release after the window stops it")
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-publisher-engine stop ").count, 1)
        XCTAssertEqual(capture.calls.filter { $0 == .stop }.count, 1, "the capture engine is not stopped twice")
        XCTAssertFalse(harness.state.processedMicrophoneEngineForTesting.isRunning)
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
    }

    func testAFailedAppleStartWhoseCaptureStopTheWindowArmsInKeepsThePublisherAndTheMode() {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: .apple)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        // The capture engine's start fails in the ordinary way, with no
        // window armed, so the start releases what it built: the capture
        // engine's stop, inside which a listener advances the generation,
        // and then the publisher's.
        var fired = false
        harness.onVoiceProcessingEngineCall { [unowned harness] engine, call in
            if call == .loadIONodes, !fired {
                engine.startError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareNotRunningError))
            }
            if call == .stop, !fired {
                fired = true
                harness.fireSystemNotification(.defaultInput)
            }
        }
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        guard
            let capture = harness.voiceProcessingEngines.engines.first,
            let publisher = harness.publisherEngines.engines.first
        else {
            return XCTFail("the engines were not built")
        }

        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap])
        XCTAssertEqual(lastOperation(of: publisher), .start, "the publisher's stop is not made inside the window")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-publisher-engine interrupt ").count, 1)
        XCTAssertEqual(
            harness.state.microphoneProcessingMode,
            .apple,
            "a failure a window armed in is not reported as a failure of the mode"
        )

        passWindow(harness)

        XCTAssertEqual(lastOperation(of: publisher), .stop, "the release after the window stops the kept publisher")
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-publisher-engine stop ").count, 1)
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
    }

    func testThePublicationIsNotWithdrawnUnderAPublisherWhoseStopWasHeldBack() {
        let harness = runningHarness(mode: .off)
        defer { harness.tearDown() }
        guard let publisher = harness.publisherEngines.engines.last else {
            return XCTFail("no publisher was built")
        }
        // Inside a window, the consuming app closes the device and the
        // feature is switched off: the release owes the whole teardown, the
        // engines' stop and then the publication's withdrawal.
        harness.fireSystemNotification(.defaultInput)
        harness.settle()
        harness.setPublishedDeviceInUse(false)
        harness.settle()
        harness.state.setProcessedMicrophoneEnabled(false)
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)
        let before = harness.hal.calls.count
        advanceTheGenerationInsideTheNextRelease(harness)

        passWindow(harness)

        XCTAssertEqual(
            harness.lifecycleCalls(after: before),
            [],
            "the muted tap and its aggregate device are not destroyed under a publisher that still renders"
        )
        XCTAssertEqual(lastOperation(of: publisher), .start)

        passWindow(harness)

        XCTAssertEqual(
            captureReleases(harness, after: before),
            [.stop(microphone), .destroyIOProc(microphone)],
            "the release after the window carries the owed teardown out"
        )
        XCTAssertEqual(
            publicationCalls(harness, after: before),
            [.destroyAggregate(aggregate), .destroyProcessTap(tap)]
        )
        XCTAssertEqual(lastOperation(of: publisher), .stop)
        let publisherStop = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-publisher-engine stop ")
        let withdrawal = harness.timelineIndex(of: .destroyAggregate(aggregate))
        XCTAssertNotNil(publisherStop)
        XCTAssertNotNil(withdrawal)
        if let publisherStop, let withdrawal {
            XCTAssertLessThan(publisherStop, withdrawal, "the publisher stops before its muted tap goes")
        }
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)
    }

    // MARK: A publisher build that fails after the generation advanced

    /// Launches with `mode` and publishes. The first publisher engine made
    /// from then on reads back another output than the one it was bound to,
    /// an ordinary failure of the build, and a default-input listener fires
    /// inside its bind, after the build's check before that bind has passed.
    private func failingBuildHarness(
        mode: MicrophoneProcessingMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioStateHarness {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: mode)
        harness.launchAndPublish(file: file, line: line)
        var first = true
        harness.publisherEngines.prepare = { [unowned harness] publisher in
            guard first else {
                return
            }
            first = false
            publisher.readBack = AudioStateHarness.usbOutput
            var fired = false
            publisher.onCall = { call in
                guard case .bindOutput = call, !fired else {
                    return
                }
                fired = true
                harness.fireSystemNotification(.defaultInput)
            }
        }
        return harness
    }

    func testAPublisherBuildThatFailsAfterTheGenerationAdvancedKeepsTheIOProcAndTheMode() {
        let harness = failingBuildHarness(mode: .webRTCLow)
        defer { harness.tearDown() }
        let before = harness.hal.calls.count

        harness.setPublishedDeviceInUse(true)
        harness.settle()

        guard let publisher = harness.publisherEngines.engines.first else {
            return XCTFail("no publisher was built")
        }
        XCTAssertFalse(publisher.calls.contains(.prepare), "the build failed at its bind")
        XCTAssertEqual(
            harness.lifecycleCalls(after: before),
            [.stop(microphone), .destroyIOProc(microphone), .createIOProc(microphone)],
            "the meter hands the input over, and the IOProc created for the start is not destroyed inside the window"
        )
        XCTAssertEqual(
            harness.hal.calls.dropFirst(before).filter { $0 == .removePropertyListener(microphone) }.count,
            3,
            "only the meter's listeners are removed, with the hand-off; the capture's stay"
        )
        let interrupt = harness.lines(withPrefix: "processed-microphone-capture-ioproc interrupt ")
        XCTAssertEqual(interrupt.count, 1, "\(interrupt)")
        XCTAssertEqual(
            generation(of: interrupt.first),
            generation(of: harness.lines(withPrefix: "processed-microphone-capture-ioproc create ").last),
            "the generation the start was issued in"
        )
        XCTAssertNil(interrupt.first.flatMap { AudioStateHarness.field("reason", of: $0) })
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-capture-ioproc destroy").isEmpty)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .webRTCLow, "not a failure of the mode")
        XCTAssertNil(harness.state.microphoneProcessingMessage)
        XCTAssertEqual(harness.state.processedMicrophoneState, .starting)
        let kept = harness.hal.calls.count

        passWindow(harness)
        for _ in 0..<4 where harness.state.processedMicrophoneState != .active {
            passWindow(harness)
        }

        let released = harness.lifecycleCalls(after: kept)
        XCTAssertEqual(
            Array(released.prefix(1)),
            [.destroyIOProc(microphone)],
            "the release after the window destroys the unstarted IOProc first: \(released)"
        )
        XCTAssertEqual(harness.publisherEngines.engines.count, 2, "and starts again")
        XCTAssertEqual(harness.state.microphoneProcessingMode, .webRTCLow)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
    }

    func testAPublisherBuildThatFailsWithNoWindowArmedStillTurnsTheModeOff() {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: .webRTCLow)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        var first = true
        harness.publisherEngines.prepare = { publisher in
            if first {
                first = false
                publisher.readBack = AudioStateHarness.usbOutput
            }
        }

        harness.setPublishedDeviceInUse(true)
        harness.settle()

        XCTAssertEqual(harness.state.microphoneProcessingMode, .off, "an ordinary failure is still one of the mode")
        XCTAssertNotNil(harness.state.microphoneProcessingMessage)
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-capture-ioproc interrupt ").count, 0)
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-capture-ioproc destroy ").count,
            1,
            "and the IOProc the failed start created is released at once"
        )
    }

    func testAFailedPublisherStartWhoseStopTheWindowArmsInKeepsTheIOProcAndDoesNotHalt() {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: .off)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        var first = true
        harness.publisherEngines.prepare = { [unowned harness] publisher in
            guard first else {
                return
            }
            first = false
            publisher.startError = NSError(domain: NSOSStatusErrorDomain, code: -10_868)
            // The failed start is stopped at once, no window having armed,
            // and the listener fires while that stop is on its way.
            publisher.onCall = { call in
                if call == .stop {
                    harness.fireSystemNotification(.defaultInput)
                }
            }
        }

        harness.setPublishedDeviceInUse(true)
        harness.settle()

        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-capture-ioproc interrupt ").count, 1)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-capture-ioproc destroy").isEmpty)
        XCTAssertEqual(harness.state.processedMicrophoneState, .starting, "not halted for a failure a device change caused")

        for _ in 0..<5 where harness.state.processedMicrophoneState != .active {
            passWindow(harness)
        }
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-capture-ioproc destroy ").count, 1)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
        XCTAssertEqual(beginLinesInsideAWindow(harness), [])
    }
}
