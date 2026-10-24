import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// How `AudioState` runs Apple voice processing, through the harness and a
/// fake voice-processing engine: nothing reaches coreaudiod.
final class AudioStateVoiceProcessingTests: XCTestCase {
    private let microphone = AudioStateHarness.builtInMicrophone

    /// Launches with `mode` selected, publishes, and has a consuming app open
    /// the published device, so the engines run.
    private func runningHarness(
        mode: MicrophoneProcessingMode = .apple,
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

    private func timelineIndex(_ harness: AudioStateHarness, _ prefix: String) -> Int? {
        harness.timelineIndex(ofLineWithPrefix: prefix)
    }

    func testAConsumerStartsTheCaptureEngineOnTheWiredDefaultsAfterThePublisher() {
        let harness = runningHarness()
        defer { harness.tearDown() }

        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 1)
        XCTAssertEqual(
            harness.voiceProcessingEngines.engines.last?.calls,
            [.loadIONodes, .enableVoiceProcessing, .bindDevices, .configureVoiceProcessing, .readInputFormat, .readOutputFormat,
             .installTap, .prepare, .start]
        )
        let prepareBegin = timelineIndex(harness, "processed-microphone-voice-processing-engine prepare-begin ")
        let prepare = timelineIndex(harness, "fake-voice-processing-engine prepare")
        let prepareLine = timelineIndex(harness, "processed-microphone-voice-processing-engine prepare ")
        XCTAssertNotNil(prepareBegin)
        XCTAssertNotNil(prepare)
        XCTAssertNotNil(prepareLine)
        if let prepareBegin, let prepare, let prepareLine, let captureStartBegin = timelineIndex(
            harness,
            "processed-microphone-voice-processing-engine start-begin "
        ) {
            XCTAssertLessThan(prepareBegin, prepare)
            XCTAssertLessThan(prepare, prepareLine)
            XCTAssertLessThan(prepareLine, captureStartBegin, "the engine is prepared, and logged, before its start")
        }
        let prepareGeneration = harness.lines(withPrefix: "processed-microphone-voice-processing-engine prepare ").last
            .flatMap { AudioStateHarness.field("gen", of: $0) }
        let startGeneration = harness.lines(withPrefix: "processed-microphone-voice-processing-engine start ").last
            .flatMap { AudioStateHarness.field("gen", of: $0) }
        XCTAssertNotNil(prepareGeneration)
        XCTAssertEqual(prepareGeneration, startGeneration, "both carry the generation the start was issued in")
        let publisherStart = timelineIndex(harness, "processed-microphone-publisher-ioproc start ")
        let captureStartBegin = timelineIndex(harness, "processed-microphone-voice-processing-engine start-begin ")
        let captureStart = timelineIndex(harness, "fake-voice-processing-engine start")
        XCTAssertNotNil(publisherStart)
        XCTAssertNotNil(captureStartBegin)
        XCTAssertNotNil(captureStart)
        if let publisherStart, let captureStartBegin, let captureStart {
            XCTAssertLessThan(publisherStart, captureStartBegin, "the publisher runs before the capture starts")
            XCTAssertLessThan(captureStartBegin, captureStart, "the begin line is written immediately before the start")
        }
        let startLine = harness.lines(withPrefix: "processed-microphone-voice-processing-engine start ").last
        XCTAssertEqual(startLine.flatMap { AudioStateHarness.field("id", of: $0) }, "\(microphone)")
        XCTAssertEqual(startLine.flatMap { AudioStateHarness.field("transport", of: $0) }, "builtIn")
        XCTAssertEqual(harness.state.microphoneDisplay, .notMeasured(.handedOff))
    }

    // MARK: The binding

    func testTheCaptureEngineIsBoundToTheCheckedInputAndOutputBeforeItsFormatsAreRead() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard let engine = harness.voiceProcessingEngines.engines.last else {
            return XCTFail("no voice-processing engine was built")
        }

        XCTAssertEqual(engine.boundDevices?.input, microphone, "bound to the default input the start read")
        XCTAssertEqual(engine.boundDevices?.output, AudioStateHarness.speakers, "and to the default output")
        let calls = engine.calls
        guard
            let enable = calls.firstIndex(of: .enableVoiceProcessing),
            let bind = calls.firstIndex(of: .bindDevices),
            let formatRead = calls.firstIndex(of: .readInputFormat)
        else {
            return XCTFail("\(calls)")
        }
        XCTAssertLessThan(enable, bind, "enabling voice processing replaces the unit, so the bind follows it")
        XCTAssertLessThan(bind, formatRead, "and comes before any format is read")
        let startLine = harness.lines(withPrefix: "processed-microphone-voice-processing-engine start ").last
        XCTAssertEqual(startLine.flatMap { AudioStateHarness.field("id", of: $0) }, "\(microphone)")
        XCTAssertEqual(
            startLine.flatMap { AudioStateHarness.field("output", of: $0) },
            "\(AudioStateHarness.speakers)",
            "the line names the output element's device too"
        )
    }

    /// Records, each time a publisher IOProc is created, the calls the first
    /// voice-processing engine had received by then. A failed start of the
    /// mode falls back to processing off, whose own start creates a
    /// publisher, so the question is what came before it.
    private func recordingCaptureCallsAtEachPublisherBuild(
        _ harness: AudioStateHarness
    ) -> Recorded<[FakeVoiceProcessingEngine.Call]> {
        let recorded = Recorded<[FakeVoiceProcessingEngine.Call]>()
        harness.holds.onEnter = { point in
            if case let .hal(.createIOProc(id)) = point, AudioStateHarness.publisherOutputs.contains(id) {
                recorded.append(harness.voiceProcessingEngines.engines.first?.calls ?? [])
            }
        }
        return recorded
    }

    func testABindingThatReadsBackAnotherOutputRefusesTheStartBeforeAnythingIsOpened() {
        var atPublisherBuilds = Recorded<[FakeVoiceProcessingEngine.Call]>()
        let harness = consumerHarness { harness in
            atPublisherBuilds = recordingCaptureCallsAtEachPublisherBuild(harness)
            let once = Once()
            harness.onVoiceProcessingEngineCall { engine, call in
                if call == .loadIONodes {
                    once { engine.boundOutputReadBack = AudioStateHarness.usbOutput }
                }
            }
        }
        defer { harness.tearDown() }
        guard let first = harness.voiceProcessingEngines.engines.first else {
            return XCTFail("no voice-processing engine was built")
        }

        XCTAssertEqual(
            first.calls,
            [.loadIONodes, .enableVoiceProcessing, .bindDevices, .stop],
            "no format read, tap, prepare or start follows a binding that did not take"
        )
        XCTAssertTrue(
            atPublisherBuilds.values.allSatisfy { $0.last == .stop },
            "no publisher is built for the refused start; the one processing off builds comes after its stop"
        )
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 1, "and the start is not tried again")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine prepare").isEmpty)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .off, "a failed start of the mode, as before")
    }

    func testABindingThatFailsRefusesTheStartBeforeAnythingIsOpened() {
        var atPublisherBuilds = Recorded<[FakeVoiceProcessingEngine.Call]>()
        let harness = consumerHarness { harness in
            atPublisherBuilds = recordingCaptureCallsAtEachPublisherBuild(harness)
            let once = Once()
            harness.onVoiceProcessingEngineCall { engine, call in
                if call == .loadIONodes {
                    once { engine.bindError = NSError(domain: NSOSStatusErrorDomain, code: -10849) }
                }
            }
        }
        defer { harness.tearDown() }
        guard let first = harness.voiceProcessingEngines.engines.first else {
            return XCTFail("no voice-processing engine was built")
        }

        XCTAssertEqual(first.calls, [.loadIONodes, .enableVoiceProcessing, .bindDevices, .stop])
        XCTAssertTrue(atPublisherBuilds.values.allSatisfy { $0.last == .stop })
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 1)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .off)
    }

    func testAnIdleStopStopsTheCaptureEngineThenThePublisher() {
        let harness = runningHarness()
        defer { harness.tearDown() }

        harness.setPublishedDeviceInUse(false)
        harness.settle()
        harness.advance(by: 3.1)
        harness.poll()

        XCTAssertEqual(
            harness.voiceProcessingEngines.engines.last?.calls.suffix(2),
            [.stop, .removeTap]
        )
        let captureStop = timelineIndex(harness, "processed-microphone-voice-processing-engine stop ")
        let publisherStop = timelineIndex(harness, "processed-microphone-publisher-ioproc stop ")
        XCTAssertNotNil(captureStop)
        XCTAssertNotNil(publisherStop)
        if let captureStop, let publisherStop {
            XCTAssertLessThan(captureStop, publisherStop)
        }
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
    }

    // MARK: The start's own checks

    /// Set once, from a hook that must act on the first engine only.
    private final class Once {
        private var done = false

        func callAsFunction(_ body: () -> Void) {
            guard !done else {
                return
            }
            done = true
            body()
        }
    }

    /// Values a hook appends, read after the harness settles.
    private final class Recorded<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Value] = []

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return _values
        }

        func append(_ value: Value) {
            lock.lock()
            _values.append(value)
            lock.unlock()
        }
    }

    /// Launches with `mode`, Apple voice processing unless given, publishes,
    /// lets `configure` install its hooks, then has a consumer open the
    /// published device.
    private func consumerHarness(
        mode: MicrophoneProcessingMode = .apple,
        _ configure: (AudioStateHarness) -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioStateHarness {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: mode)
        harness.launchAndPublish(file: file, line: line)
        configure(harness)
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        return harness
    }

    private let speakers = AudioStateHarness.speakers

    /// Lets windows pass until the processed microphone is active again.
    private func releaseUntilActive(_ harness: AudioStateHarness) {
        for _ in 0..<5 where harness.state.processedMicrophoneState != .active {
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
        }
    }

    /// The processed microphone engines' `stop-begin` lines that a quiet
    /// window holds, judged as the gate's criterion 10 judges them: a
    /// generation below the highest held or advanced so far, or equal to it
    /// before that generation's release. `gen=-` lines are not judged.
    private func engineStopsInsideAWindow(_ harness: AudioStateHarness) -> [String] {
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
                line.hasPrefix("processed-microphone-voice-processing-engine stop-begin ")
                    || line.hasPrefix("processed-microphone-publisher-ioproc stop-begin "),
                let generation,
                generation < highest || (generation == highest && !released.contains(generation))
            {
                hits.append(line)
            }
        }
        return hits
    }

    func testAnOutputWithoutAUsableFormatAfterEnablingVoiceProcessingKeepsTheEngineForTheRelease() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.onVoiceProcessingEngineCall { engine, call in
                if call == .loadIONodes {
                    once { engine.outputReportsNoSampleRate = true }
                }
            }
        }
        defer { harness.tearDown() }
        guard let first = harness.voiceProcessingEngines.engines.first else {
            return XCTFail("no voice-processing engine was built")
        }

        XCTAssertEqual(
            first.calls,
            [.loadIONodes, .enableVoiceProcessing, .bindDevices, .configureVoiceProcessing, .readInputFormat, .readOutputFormat],
            "neither a tap nor a start follows, and the engine is not released inside the change"
        )
        XCTAssertEqual(harness.publisherCreates, 0, "no publisher was created")
        XCTAssertEqual(harness.holdReasons.last, "processing-invalidated")
        XCTAssertEqual(harness.state.microphoneProcessingMode, .apple, "not a failure of the mode")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine start").isEmpty)

        releaseUntilActive(harness)
        XCTAssertEqual(first.calls.last, .stop, "the release after the window stops the kept engine")
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 2)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testAWindowArmedWhileVoiceProcessingIsEnabledHoldsTheBindBack() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.onVoiceProcessingEngineCall { _, call in
                if call == .enableVoiceProcessing {
                    once { harness.fireSystemNotification(.defaultInput) }
                }
            }
        }
        defer { harness.tearDown() }
        guard let first = harness.voiceProcessingEngines.engines.first else {
            return XCTFail("no voice-processing engine was built")
        }

        XCTAssertEqual(
            first.calls,
            [.loadIONodes, .enableVoiceProcessing],
            "no device is selected and no format read inside the window, and nothing is stopped there"
        )
        XCTAssertNil(first.boundDevices)
        XCTAssertEqual(harness.publisherCreates, 0, "no publisher was created")
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .apple, "not a failure of the mode")

        releaseUntilActive(harness)
        XCTAssertEqual(first.calls.last, .stop, "the release after the window stops the engine it kept, never bound")
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 2)
        XCTAssertEqual(harness.voiceProcessingEngines.engines.last?.boundDevices?.input, microphone)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testAWindowArmedBeforeThePublisherIsBuiltKeepsTheUnstartedEngineForTheRelease() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.onVoiceProcessingEngineCall { _, call in
                if call == .readOutputFormat {
                    once { harness.fireSystemNotification(.defaultInput) }
                }
            }
        }
        defer { harness.tearDown() }
        guard let first = harness.voiceProcessingEngines.engines.first else {
            return XCTFail("no voice-processing engine was built")
        }

        XCTAssertEqual(
            first.calls,
            [.loadIONodes, .enableVoiceProcessing, .bindDevices, .configureVoiceProcessing, .readInputFormat, .readOutputFormat],
            "nothing more is issued, and nothing is stopped inside the window"
        )
        XCTAssertEqual(harness.publisherCreates, 0, "the publisher is not created")
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)

        releaseUntilActive(harness)
        XCTAssertEqual(first.calls.last, .stop, "the release after the window stops the kept engine")
        XCTAssertFalse(first.calls.contains(.removeTap), "it had no tap")
        XCTAssertTrue(
            harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop").isEmpty,
            "an engine that never started gets no stop lines"
        )
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 2)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testAWindowArmedWhileThePublisherOutputIsReadAgainKeepsThePublisherUncreatedUntilTheRelease() {
        let usbOutput = AudioStateHarness.usbOutput
        let harness = consumerHarness { harness in
            // A USB default output is read again on the lifecycle queue
            // immediately before the publisher's IOProc is created; the
            // window arms there.
            harness.moveDefaultOutput(to: usbOutput)
            harness.hal.listedOutputDevices = [FakeAudioSystem.usbOutputDevice]
            harness.hal.setTransportInfo(AudioDeviceTransportInfo(transport: .usb), for: usbOutput)
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
            let once = Once()
            harness.hal.onRead = { read in
                guard
                    case let .transportInfo(deviceID) = read,
                    deviceID == usbOutput,
                    harness.voiceProcessingEngines.engines.last?.calls.last == .readOutputFormat
                else {
                    return
                }
                once { harness.fireSystemNotification(.defaultInput) }
            }
        }
        defer { harness.tearDown() }
        guard let capture = harness.voiceProcessingEngines.engines.first else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertFalse(harness.hal.lifecycleCalls.contains(.createIOProc(usbOutput)), "the publisher is not created after the window armed")
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-publisher-ioproc interrupt ").count, 1)
        XCTAssertFalse(capture.calls.contains(.installTap), "the tap is not installed")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine prepare").isEmpty)
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)

        releaseUntilActive(harness)
        XCTAssertEqual(capture.calls.last, .stop)
        XCTAssertTrue(
            harness.lines(withPrefix: "processed-microphone-publisher-ioproc stop").isEmpty,
            "a publisher whose start was never issued gets no stop lines"
        )
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testAWindowArmedWhileThePublisherIsCreatedKeepsItUnstartedForTheReleaseInEveryMode() {
        for mode in [MicrophoneProcessingMode.off, .apple] {
            let speakers = speakers
            let harness = consumerHarness(mode: mode) { harness in
                let once = Once()
                harness.holds.onEnter = { point in
                    if point == .hal(.createIOProc(speakers)) {
                        once { harness.fireSystemNotification(.defaultInput) }
                    }
                }
            }
            defer { harness.tearDown() }
            XCTAssertEqual(harness.publisherCreates, 1, "\(mode)")
            XCTAssertFalse(harness.hal.lifecycleCalls.contains(.start(speakers)), "the publisher does not start after the window armed: \(mode)")
            XCTAssertFalse(harness.hal.lifecycleCalls.contains(.destroyIOProc(speakers)), "nor is it released inside the window: \(mode)")
            XCTAssertTrue(
                harness.lines(withPrefix: "processed-microphone-publisher-ioproc start-begin ").isEmpty,
                "no start-begin line follows the advance: \(mode)"
            )
            XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-publisher-ioproc interrupt ").count, 1, "\(mode)")
            if mode == .apple {
                XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)
                XCTAssertFalse(harness.voiceProcessingEngines.engines.first?.calls.contains(.installTap) ?? true)
            } else {
                XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-capture-ioproc start-begin ").isEmpty)
            }

            releaseUntilActive(harness)
            XCTAssertTrue(harness.hal.lifecycleCalls.contains(.destroyIOProc(speakers)), "the release after the window destroys it: \(mode)")
            XCTAssertTrue(
                harness.lines(withPrefix: "processed-microphone-publisher-ioproc stop").isEmpty,
                "without stop lines, since its start was never issued: \(mode)"
            )
            XCTAssertEqual(engineStopsInsideAWindow(harness), [], "\(mode)")
            XCTAssertEqual(harness.state.processedMicrophoneState, .active, "\(mode)")
        }
    }

    // MARK: A call that raises

    func testAnInstallTapThatRaisesKeepsBothEnginesUnstoppedUntilTheRelease() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.onVoiceProcessingEngineCall { engine, call in
                if call == .loadIONodes {
                    once { engine.raisesAt = .installTap }
                }
            }
        }
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the tap")
        }

        XCTAssertEqual(capture.calls.last, .installTap, "nothing is called on the engine after it raised, its stop included")
        XCTAssertEqual(harness.lastPublisherCall, .start(speakers), "the publisher keeps rendering into the muted tap")
        let interrupt = harness.lines(withPrefix: "processed-microphone-source interrupt ").last
        XCTAssertEqual(interrupt.flatMap { AudioStateHarness.field("reason", of: $0) }, "engine-raised")
        XCTAssertEqual(harness.holdReasons.last, "processing-invalidated", "the raise holds the window")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-ioproc stop").isEmpty)
        XCTAssertTrue(harness.state.processedMicrophoneEngineForTesting.retiredEnginesForTesting.isEmpty, "nothing is freed")
        XCTAssertEqual(harness.state.microphoneProcessingMode, .apple, "not a failure of the mode")

        releaseUntilActive(harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the release after the window stops it")
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.destroyIOProc(speakers)))
        XCTAssertEqual(engineStopsInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
        XCTAssertEqual(
            harness.voiceProcessingEngines.engines.last?.tapFormatGiven,
            .some(nil),
            "the tap is installed with no format, so the node's format at that moment is used"
        )
    }

    func testStartsThatKeepRaisingAreReportedAsAFailureOnTheFourthWithNoStopInsideAWindow() {
        let harness = consumerHarness { harness in
            harness.onVoiceProcessingEngineCall { engine, call in
                if call == .loadIONodes {
                    engine.raisesAt = .prepare
                }
            }
        }
        defer { harness.tearDown() }

        for _ in 0..<12 where harness.state.microphoneProcessingMode == .apple {
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
        }

        let maximum = ProcessedMicrophoneEngine.maximumConsecutiveEngineRaises
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, maximum)
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-source interrupt ").filter { $0.contains("reason=engine-raised") }.count,
            maximum
        )
        XCTAssertEqual(
            harness.state.microphoneProcessingMode,
            .off,
            "the last raise in a row is a failure of the mode, as a failed start is"
        )
        XCTAssertEqual(engineStopsInsideAWindow(harness), [])
    }

    func testAWindowArmedBeforeTheEngineStartsLeavesThePublisherAndTheTapForTheRelease() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.onVoiceProcessingEngineCall { _, call in
                if call == .prepare {
                    once { harness.fireSystemNotification(.defaultInput) }
                }
            }
        }
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertEqual(capture.calls.last, .prepare, "the engine does not start")
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-voice-processing-engine prepare ").count,
            1,
            "the prepare the kept engine went through is on the log"
        )
        XCTAssertFalse(harness.hal.lifecycleCalls.contains(.stop(speakers)))
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine start").isEmpty)

        releaseUntilActive(harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the release removes the tap it kept")
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.destroyIOProc(speakers)))
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop").isEmpty)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testADefaultThatMovedJustBeforeTheEngineStartsHoldsTheWindowBeforeReleasingAnything() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.onVoiceProcessingEngineCall { _, call in
                if call == .prepare {
                    once { harness.hal.currentDefaultInputID = AudioStateHarness.usbMicrophone }
                }
            }
        }
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertEqual(
            capture.calls,
            [.loadIONodes, .enableVoiceProcessing, .bindDevices, .configureVoiceProcessing, .readInputFormat, .readOutputFormat,
             .installTap, .prepare],
            "the engine is neither started nor released inside the change"
        )
        let refuse = harness.lines(withPrefix: "processed-microphone-source refuse ").last
        XCTAssertEqual(refuse.flatMap { AudioStateHarness.field("id", of: $0) }, "\(AudioStateHarness.usbMicrophone)")
        XCTAssertEqual(refuse.flatMap { AudioStateHarness.field("transport", of: $0) }, "moved")
        XCTAssertEqual(harness.lastPublisherCall, .start(speakers), "the publisher the start built keeps running")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine start").isEmpty)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-ioproc stop").isEmpty)
        XCTAssertEqual(harness.holdReasons.last, "processing-refused")
        let refuseIndex = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-source refuse ")
        let holdIndex = harness.timelineIndex(ofLineWithPrefix: "quiet-window hold reason=processing-refused ")
        XCTAssertNotNil(refuseIndex)
        XCTAssertNotNil(holdIndex)
        if let refuseIndex, let holdIndex {
            XCTAssertLessThan(refuseIndex, holdIndex)
        }
        XCTAssertNotEqual(harness.state.processedMicrophoneState, .active)

        harness.hal.currentDefaultInputID = AudioStateHarness.builtInMicrophone
        releaseUntilActive(harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the release stops the kept engine")
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.destroyIOProc(speakers)), "and the publisher")
        XCTAssertTrue(
            harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop").isEmpty,
            "an engine that never started gets no stop lines"
        )
        XCTAssertEqual(engineStopsInsideAWindow(harness), [])
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 2)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testADefaultThatMovedWhileTheEngineStartedStopsBothEnginesOnlyAfterTheWindow() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.onVoiceProcessingEngineCall { _, call in
                if call == .start {
                    once { harness.hal.currentDefaultOutputID = AudioStateHarness.usbOutput }
                }
            }
        }
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertEqual(capture.calls.last, .start, "the engine that started is not stopped inside the change")
        XCTAssertEqual(harness.lastPublisherCall, .start(speakers))
        let start = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-voice-processing-engine start ")
        let refuse = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-source refuse id=\(AudioStateHarness.usbOutput) transport=moved ")
        let hold = harness.timelineIndex(ofLineWithPrefix: "quiet-window hold reason=processing-refused ")
        XCTAssertNotNil(start)
        XCTAssertNotNil(refuse)
        XCTAssertNotNil(hold)
        if let start, let refuse, let hold {
            XCTAssertLessThan(start, refuse, "the defaults are read again once the start has returned")
            XCTAssertLessThan(refuse, hold, "and the window arms before anything is released")
        }
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop").isEmpty)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-ioproc stop").isEmpty)
        XCTAssertEqual(harness.holdReasons.last, "processing-refused")
        XCTAssertNotEqual(harness.state.processedMicrophoneState, .active)

        harness.hal.currentDefaultOutputID = AudioStateHarness.speakers
        releaseUntilActive(harness)
        XCTAssertTrue(capture.calls.contains(.stop), "the release stops the engine that started")
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.destroyIOProc(speakers)))
        let stop = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-voice-processing-engine stop ")
        let publisherStop = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-publisher-ioproc stop ")
        XCTAssertNotNil(stop, "with its stop lines")
        XCTAssertNotNil(publisherStop)
        if let stop, let publisherStop {
            XCTAssertLessThan(stop, publisherStop, "before the publisher")
        }
        XCTAssertEqual(engineStopsInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testADefaultMovedWithItsNotificationWhileTheEngineStartedIsNotStoppedInThatWindow() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.onVoiceProcessingEngineCall { _, call in
                if call == .start {
                    once {
                        // macOS moves the default output, and its listener
                        // advances the generation before start() returns.
                        harness.hal.currentDefaultOutputID = AudioStateHarness.usbOutput
                        harness.fireSystemNotification(.defaultOutput)
                    }
                }
            }
        }
        defer { harness.tearDown() }
        guard let capture = harness.voiceProcessingEngines.engines.first else {
            return XCTFail("no voice-processing engine was built")
        }

        XCTAssertEqual(capture.calls.last, .start)
        XCTAssertEqual(harness.lines(withPrefix: "quiet-window advance source=hal-notification ").count, 1)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop").isEmpty)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-ioproc stop").isEmpty)

        harness.hal.currentDefaultOutputID = AudioStateHarness.speakers
        releaseUntilActive(harness)
        XCTAssertTrue(capture.calls.contains(.stop), "the release after the window stops it")
        XCTAssertFalse(harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop-begin ").isEmpty)
        XCTAssertEqual(engineStopsInsideAWindow(harness), [], "no stop carries a generation the window holds")
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testAWindowArmedWhileTheDefaultsAreReadBeforeTheStartLeavesTheEngineUnstarted() {
        let harness = consumerHarness { harness in
            let once = Once()
            harness.hal.onRead = { read in
                // The default output read immediately before the start, once
                // the engine is prepared. The listener advances the generation
                // and leaves both defaults where they were.
                guard
                    Thread.isMainThread,
                    read == .defaultOutputDeviceID,
                    harness.voiceProcessingEngines.engines.last?.calls.last == .prepare
                else {
                    return
                }
                once { harness.fireSystemNotification(.defaultSystemOutput) }
            }
        }
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertEqual(capture.calls.last, .prepare, "the engine does not start")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine start").isEmpty)
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-source refuse ").isEmpty, "no default moved")

        releaseUntilActive(harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the release stops the kept engine")
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.destroyIOProc(speakers)))
        XCTAssertEqual(engineStopsInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    // MARK: The app's own pickers

    /// The engines run, a headset has just connected, the window its arrival
    /// armed holds them, and the pickers list it.
    private func harnessWithHeadsetListed(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioStateHarness {
        let harness = runningHarness(file: file, line: line)
        harness.connectHeadset()
        // A device-list notification asks for a poll with the device lists.
        harness.fireSystemNotification(.devices)
        harness.settle()
        XCTAssertEqual(harness.holdReasons.last, "bluetooth-devices", file: file, line: line)
        return harness
    }

    /// Notes each default-device write in the timeline, as
    /// `default-device-write id=<device>`.
    private func noteDefaultDeviceWrites(_ harness: AudioStateHarness) {
        let hal = harness.hal
        harness.holds.onEnter = { point in
            if case let .defaultDeviceWrite(deviceID) = point {
                hal.noteLine("default-device-write id=\(deviceID)")
            }
        }
    }

    private func select(_ deviceID: AudioDeviceID, _ direction: AudioDirection, in harness: AudioStateHarness) {
        if direction == .output {
            harness.state.selectOutputDevice(deviceID)
        } else {
            harness.state.selectInputDevice(deviceID)
        }
        harness.settle()
    }

    func testPickingABluetoothDeviceWhileItsArrivalHoldsTheWindowStopsAndWritesNothing() {
        for direction in [AudioDirection.output, .input] {
            let harness = harnessWithHeadsetListed()
            defer { harness.tearDown() }
            guard let engine = harness.voiceProcessingEngines.engines.last else {
                XCTFail("no voice-processing engine was built")
                continue
            }
            let headset = AudioStateHarness.headset
            let listed = direction == .output ? harness.state.outputDevices : harness.state.inputDevices
            XCTAssertTrue(listed.contains { $0.id == headset }, "\(direction)")
            XCTAssertEqual(engine.calls.last, .start, "the window holds the engines until the pick: \(direction)")
            let selected = direction == .output ? harness.state.outputDeviceID : harness.state.inputDeviceID
            noteDefaultDeviceWrites(harness)

            select(headset, direction, in: harness)

            XCTAssertEqual(engine.calls.last, .start, "nothing is stopped inside the headset's change: \(direction)")
            XCTAssertFalse(harness.lines.values.contains { $0.contains("reason=bluetooth-selection") }, "\(direction)")
            XCTAssertNil(harness.timelineIndex(ofLineWithPrefix: "default-device-write "), "nor written: \(direction)")
            XCTAssertEqual(
                harness.lines(withPrefix: "picker refuse "),
                ["picker refuse id=\(headset) direction=\(direction == .output ? "output" : "input") transport=bluetooth gen=\(lastHoldGeneration(harness))"]
            )
            XCTAssertEqual(
                direction == .output ? harness.state.outputDeviceID : harness.state.inputDeviceID,
                selected,
                "the picker stays on the current default: \(direction)"
            )

            // The release after the window stops the engines, since a
            // headset is connected, and the same pick then goes ahead.
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
            XCTAssertEqual(Array(engine.calls.suffix(2)), [.stop, .removeTap], "\(direction)")
            XCTAssertEqual(engineStopsInsideAWindow(harness), [], "\(direction)")

            select(headset, direction, in: harness)
            XCTAssertNotNil(harness.timelineIndex(ofLineWithPrefix: "default-device-write id=\(headset)"), "\(direction)")
            XCTAssertEqual(harness.lines(withPrefix: "picker refuse ").count, 1, "\(direction)")
            XCTAssertFalse(harness.lines.values.contains { $0.contains("reason=bluetooth-selection") }, "\(direction)")
            XCTAssertEqual(harness.state.microphoneProcessingMode, .apple, "\(direction)")
        }
    }

    func testAPickThatMayInvolveBluetoothIsRefusedWhileAnotherChangeHoldsTheWindow() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard let engine = harness.voiceProcessingEngines.engines.last else {
            return XCTFail("no voice-processing engine was built")
        }
        noteDefaultDeviceWrites(harness)
        select(AudioStateHarness.usbOutput, .output, in: harness)
        XCTAssertEqual(harness.holdReasons.last, "output-selection")

        // A device the list does not show has no transport on hand.
        select(99, .input, in: harness)

        XCTAssertEqual(engine.calls.last, .start, "the wired pick's window holds, so nothing is stopped")
        XCTAssertNil(harness.timelineIndex(ofLineWithPrefix: "default-device-write id=99"))
        let refused = harness.lines(withPrefix: "picker refuse ").last
        XCTAssertEqual(refused.flatMap { AudioStateHarness.field("id", of: $0) }, "99")
        XCTAssertEqual(refused.flatMap { AudioStateHarness.field("transport", of: $0) }, "-")
        XCTAssertEqual(harness.state.inputDeviceID, microphone)
    }

    /// The publisher's `stop-begin` lines a quiet window holds.
    private func beginStopsInsideAWindowForPublisher(_ harness: AudioStateHarness) -> [String] {
        engineStopsInsideAWindow(harness).filter { $0.hasPrefix("processed-microphone-publisher-ioproc ") }
    }

    private func lastHoldGeneration(_ harness: AudioStateHarness) -> String {
        harness.lines(withPrefix: "quiet-window hold ").last.flatMap { AudioStateHarness.field("gen", of: $0) } ?? "?"
    }

    func testPickingAWiredOutputLeavesVoiceProcessingToTheEvaluationAfterTheWindow() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard let engine = harness.voiceProcessingEngines.engines.last else {
            return XCTFail("no voice-processing engine was built")
        }

        harness.state.selectOutputDevice(AudioStateHarness.usbOutput)
        harness.settle()

        XCTAssertEqual(engine.calls.last, .start, "a wired pick does not stop the engines at once")
        XCTAssertFalse(harness.lines.values.contains { $0.contains("reason=bluetooth-selection") })
        XCTAssertEqual(harness.holdReasons.last, "output-selection")
    }

    func testPickingAnUnlistedDeviceStopsVoiceProcessingBeforeTheDefaultWrite() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard let engine = harness.voiceProcessingEngines.engines.last else {
            return XCTFail("no voice-processing engine was built")
        }

        noteDefaultDeviceWrites(harness)

        // A device the list does not show has no transport on hand. No
        // window holds and no Bluetooth device is connected.
        select(99, .input, in: harness)

        XCTAssertEqual(Array(engine.calls.suffix(2)), [.stop, .removeTap])
        let stopLine = harness.lines(withPrefix: "processed-microphone-voice-processing-engine stop ").last
        XCTAssertEqual(stopLine.flatMap { AudioStateHarness.field("reason", of: $0) }, "bluetooth-selection")
        XCTAssertEqual(stopLine.flatMap { AudioStateHarness.field("gen", of: $0) }, "-")
        XCTAssertTrue(
            harness.lines(withPrefix: "processed-microphone-publisher-ioproc stop").isEmpty,
            "the publisher, on an output that never follows the default, is not stopped around the write"
        )
        XCTAssertEqual(harness.lastPublisherCall, .start(speakers))
        XCTAssertEqual(
            harness.state.processedMicrophoneEngineForTesting.livePublisherContextForTesting?.close(),
            false,
            "it renders silence"
        )
        XCTAssertTrue(harness.state.processedMicrophoneEngineForTesting.needsRestart, "and is released after the window")
        let stopBegin = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-voice-processing-engine stop-begin ")
        let hold = harness.timelineIndex(ofLineWithPrefix: "quiet-window hold reason=input-selection ")
        let write = harness.timelineIndex(ofLineWithPrefix: "default-device-write id=99")
        XCTAssertNotNil(stopBegin)
        XCTAssertNotNil(hold)
        XCTAssertNotNil(write)
        if let stopBegin, let hold, let write {
            XCTAssertLessThan(stopBegin, hold, "the engine stops before the pick's window")
            XCTAssertLessThan(hold, write, "and before the default is written")
        }
        XCTAssertTrue(harness.lines(withPrefix: "picker refuse ").isEmpty)
    }

    // MARK: Engine lifetime

    func testEnginesStoppedWhileAWindowFollowsAreFreedOnlyByAnEvaluationThatAdmitsStarts() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.last
        else {
            return XCTFail("the engines did not start")
        }
        let engine = harness.state.processedMicrophoneEngineForTesting

        // The picker's stop, then the pick's window.
        select(99, .input, in: harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap])
        XCTAssertEqual(harness.holdReasons.last, "input-selection")
        XCTAssertTrue(engine.retiredEnginesForTesting.contains { $0 === capture }, "the capture engine is not freed inside the window")
        XCTAssertFalse(harness.hal.lifecycleCalls.contains(.stop(speakers)), "nor is the publisher stopped inside it")

        harness.poll()
        XCTAssertTrue(engine.retiredEnginesForTesting.contains { $0 === capture }, "an evaluation the window holds frees nothing")

        for _ in 0..<3 where !engine.retiredEnginesForTesting.isEmpty {
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
        }
        XCTAssertFalse(engine.retiredEnginesForTesting.contains { $0 === capture }, "freed once starts are admitted")
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.stop(speakers)), "and the publisher is released after the window")
        XCTAssertEqual(beginStopsInsideAWindowForPublisher(harness), [])
    }

    func testQuitStopsTheEnginesAndKeepsThemUntilTheProcessExits() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.last
        else {
            return XCTFail("the engines did not start")
        }
        harness.hal.isRunningSomewhereRead = (noErr, 0)

        harness.state.stop()
        harness.settle()

        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "Quit still stops the capture engine")
        XCTAssertEqual(harness.lastPublisherCall, .destroyIOProc(speakers), "and releases the publisher's IOProc")
        let publisherStop = harness.lines(withPrefix: "processed-microphone-publisher-ioproc stop ").last
        XCTAssertEqual(publisherStop.flatMap { AudioStateHarness.field("reason", of: $0) }, "quit")
        let kept = ProcessedMicrophoneEngine.enginesKeptUntilExitForTesting
        XCTAssertTrue(kept.contains { $0 === capture }, "no capture engine is freed during Quit's teardown")
    }

    // MARK: Connected Bluetooth devices

    func testAConnectedBluetoothDeviceStopsVoiceProcessingAfterTheWindowAndItResumesOnceNoneIsConnected() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard let engine = harness.voiceProcessingEngines.engines.last else {
            return XCTFail("no voice-processing engine was built")
        }
        let refused = ProcessedMicrophoneState.refused(.bluetoothDevicePresentForVoiceProcessing, published: true)

        harness.connectHeadset()
        harness.poll()
        XCTAssertEqual(harness.holdReasons.last, "bluetooth-devices")
        XCTAssertEqual(harness.state.processedMicrophoneState, refused, "the reason shows at once")
        XCTAssertEqual(engine.calls.last, .start, "the window holds the stop")
        let refuseLine = harness.lines(withPrefix: "processed-microphone-source refuse ").last
        XCTAssertEqual(refuseLine.flatMap { AudioStateHarness.field("id", of: $0) }, "\(AudioStateHarness.headset)")

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(Array(engine.calls.suffix(2)), [.stop, .removeTap], "the release stops it")
        XCTAssertEqual(harness.state.processedMicrophoneState, refused)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .apple, "the switch stays on")

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 1, "nothing starts while the headset is connected")
        XCTAssertFalse(
            harness.hal.lifecycleCalls.contains(.destroyAggregate(AudioStateHarness.publishedAggregate)),
            "the publication stays"
        )

        harness.disconnectHeadset()
        harness.poll()
        XCTAssertEqual(harness.holdReasons.last, "bluetooth-devices")
        for _ in 0..<3 where harness.state.processedMicrophoneState != .active {
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
        }
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 2, "it starts again by itself")
        XCTAssertEqual(harness.voiceProcessingEngines.engines.last?.calls.last, .start)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testDeviceBoundModesKeepRunningWhileABluetoothDeviceIsConnected() {
        let harness = runningHarness(mode: .off)
        defer { harness.tearDown() }
        let beforeConnect = harness.hal.calls.count

        harness.connectHeadset()
        harness.poll()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()

        XCTAssertFalse(
            harness.lifecycleCalls(after: beforeConnect).contains(.stop(microphone)),
            "the capture bound to the built-in microphone keeps running"
        )
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testABluetoothOutputTheUncachedReadListsStopsTheStartWithoutLatchingIt() {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: .apple)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        // The headset is in the uncached output list, and not yet in the
        // poll's device list.
        let wiredOutputs = harness.hal.listedOutputDevices
        harness.hal.listedOutputDevices = (wiredOutputs ?? []) + [FakeAudioSystem.headsetDevice]

        harness.setPublishedDeviceInUse(true)
        harness.settle()

        XCTAssertTrue(harness.voiceProcessingEngines.engines.isEmpty, "no engine was built")
        XCTAssertEqual(harness.publisherCreates, 0, "nor a publisher")
        let refuseLine = harness.lines(withPrefix: "processed-microphone-source refuse ").last
        XCTAssertEqual(refuseLine.flatMap { AudioStateHarness.field("id", of: $0) }, "\(AudioStateHarness.headset)")
        XCTAssertEqual(refuseLine.flatMap { AudioStateHarness.field("transport", of: $0) }, "bluetooth")
        XCTAssertEqual(harness.holdReasons.last, "processing-refused")
        XCTAssertNotEqual(
            harness.state.processedMicrophoneState,
            .refused(.bluetoothDevicePresentForVoiceProcessing, published: true),
            "the poll has not shown the device, so it is a change to wait out"
        )

        // The next start, after the window, goes ahead once the fresh read
        // no longer lists the headset: the refusal was not latched.
        harness.hal.listedOutputDevices = wiredOutputs
        for _ in 0..<3 where harness.state.processedMicrophoneState != .active {
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
        }
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, 1)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }
}
