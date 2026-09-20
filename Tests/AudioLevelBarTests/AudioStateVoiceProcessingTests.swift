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
        let publisherStart = timelineIndex(harness, "processed-microphone-publisher-engine start ")
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

    /// Records, each time a publisher engine is built, the calls the first
    /// voice-processing engine had received by then. A failed start of the
    /// mode falls back to processing off, whose own start builds a publisher,
    /// so the question is what came before it.
    private func recordingCaptureCallsAtEachPublisherBuild(
        _ harness: AudioStateHarness
    ) -> Recorded<[FakeVoiceProcessingEngine.Call]> {
        let recorded = Recorded<[FakeVoiceProcessingEngine.Call]>()
        harness.publisherEngines.prepare = { _ in
            recorded.append(harness.voiceProcessingEngines.engines.first?.calls ?? [])
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
        let publisherStop = timelineIndex(harness, "processed-microphone-publisher-engine stop ")
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
    private final class Recorded<Value> {
        private(set) var values: [Value] = []

        func append(_ value: Value) {
            values.append(value)
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

    /// The publisher's last call other than the read-backs its log lines make.
    private func lastOperation(of publisher: FakePublisherEngine) -> FakePublisherEngine.Call? {
        publisher.calls.last { $0 != .readBoundOutput }
    }

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
                    || line.hasPrefix("processed-microphone-publisher-engine stop-begin "),
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
        XCTAssertTrue(harness.publisherEngines.engines.isEmpty, "no publisher was built")
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
        XCTAssertTrue(harness.publisherEngines.engines.isEmpty, "no publisher was built")
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
        XCTAssertTrue(harness.publisherEngines.engines.isEmpty, "the publisher is not built")
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

    func testAWindowArmedWhileThePublisherOutputIsReadAgainKeepsThePublisherUnpreparedUntilTheRelease() {
        let harness = consumerHarness { harness in
            // A USB default output is read again on the main thread
            // immediately before the publisher is prepared; the window arms
            // there.
            harness.moveDefaultOutput(to: AudioStateHarness.usbOutput)
            harness.hal.listedOutputDevices = [FakeAudioSystem.usbOutputDevice]
            harness.hal.setTransportInfo(AudioDeviceTransportInfo(transport: .usb), for: AudioStateHarness.usbOutput)
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
            let once = Once()
            harness.hal.onRead = { read in
                guard
                    Thread.isMainThread,
                    case let .transportInfo(deviceID) = read,
                    deviceID == AudioStateHarness.usbOutput
                else {
                    return
                }
                once { harness.fireSystemNotification(.defaultInput) }
            }
        }
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.first,
            let publisher = harness.publisherEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertFalse(publisher.calls.contains(.prepare), "the publisher is neither prepared after the window armed")
        XCTAssertFalse(publisher.calls.contains(.start), "nor started")
        XCTAssertFalse(publisher.calls.contains(.stop), "nor stopped inside the window")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine prepare").isEmpty)
        XCTAssertFalse(capture.calls.contains(.installTap), "the tap is not installed")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine prepare").isEmpty)
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)

        releaseUntilActive(harness)
        XCTAssertEqual(lastOperation(of: publisher), .stop, "the release after the window stops it")
        XCTAssertEqual(capture.calls.last, .stop)
        XCTAssertTrue(
            harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty,
            "a publisher whose start was never issued gets no stop lines"
        )
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testAWindowArmedWhileThePublisherPreparesKeepsItUnstartedForTheReleaseInEveryMode() {
        for mode in [MicrophoneProcessingMode.off, .apple] {
            let harness = consumerHarness(mode: mode) { harness in
                let once = Once()
                harness.publisherEngines.prepare = { publisher in
                    publisher.onCall = { call in
                        if call == .prepare {
                            once { harness.fireSystemNotification(.defaultInput) }
                        }
                    }
                }
            }
            defer { harness.tearDown() }
            guard let publisher = harness.publisherEngines.engines.first else {
                XCTFail("no publisher was built: \(mode)")
                continue
            }

            XCTAssertTrue(publisher.calls.contains(.prepare), "\(mode)")
            XCTAssertFalse(publisher.calls.contains(.start), "the publisher does not start after the window armed: \(mode)")
            XCTAssertFalse(publisher.calls.contains(.stop), "nor is it stopped inside the window: \(mode)")
            XCTAssertTrue(
                harness.lines(withPrefix: "processed-microphone-publisher-engine start-begin ").isEmpty,
                "no start-begin line follows the advance: \(mode)"
            )
            if mode == .apple {
                XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)
                XCTAssertFalse(harness.voiceProcessingEngines.engines.first?.calls.contains(.installTap) ?? true)
            } else {
                XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-capture-ioproc interrupt ").count, 1)
                XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-capture-ioproc start-begin ").isEmpty)
            }

            releaseUntilActive(harness)
            XCTAssertEqual(lastOperation(of: publisher), .stop, "the release after the window stops it: \(mode)")
            XCTAssertTrue(
                harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty,
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
            let capture = harness.voiceProcessingEngines.engines.first,
            let publisher = harness.publisherEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the tap")
        }

        XCTAssertEqual(capture.calls.last, .installTap, "nothing is called on the engine after it raised, its stop included")
        XCTAssertEqual(lastOperation(of: publisher), .start, "the publisher keeps rendering into the muted tap")
        let interrupt = harness.lines(withPrefix: "processed-microphone-source interrupt ").last
        XCTAssertEqual(interrupt.flatMap { AudioStateHarness.field("reason", of: $0) }, "engine-raised")
        XCTAssertEqual(harness.holdReasons.last, "processing-invalidated", "the raise holds the window")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)
        XCTAssertTrue(harness.state.processedMicrophoneEngineForTesting.retiredEnginesForTesting.isEmpty, "nothing is freed")
        XCTAssertEqual(harness.state.microphoneProcessingMode, .apple, "not a failure of the mode")

        releaseUntilActive(harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the release after the window stops it")
        XCTAssertEqual(lastOperation(of: publisher), .stop)
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

    func testAPublisherThatRaisesForTheIOProcCaptureIsKeptUnstoppedUntilTheRelease() {
        let harness = consumerHarness(mode: .off) { harness in
            let once = Once()
            harness.publisherEngines.prepare = { publisher in
                once { publisher.raisesAt = .prepare }
            }
        }
        defer { harness.tearDown() }
        guard let publisher = harness.publisherEngines.engines.first else {
            return XCTFail("no publisher was built")
        }

        XCTAssertEqual(lastOperation(of: publisher), .prepare, "neither started nor stopped after it raised")
        let interrupt = harness.lines(withPrefix: "processed-microphone-capture-ioproc interrupt ").last
        XCTAssertEqual(interrupt.flatMap { AudioStateHarness.field("reason", of: $0) }, "engine-raised")
        XCTAssertEqual(harness.holdReasons.last, "processing-invalidated")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-capture-ioproc start-begin ").isEmpty)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .off)

        releaseUntilActive(harness)
        XCTAssertEqual(lastOperation(of: publisher), .stop, "the release after the window stops it")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)
        XCTAssertEqual(engineStopsInsideAWindow(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
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
            let capture = harness.voiceProcessingEngines.engines.first,
            let publisher = harness.publisherEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertEqual(capture.calls.last, .prepare, "the engine does not start")
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-voice-processing-engine prepare ").count,
            1,
            "the prepare the kept engine went through is on the log"
        )
        XCTAssertFalse(publisher.calls.contains(.stop))
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine start").isEmpty)

        releaseUntilActive(harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the release removes the tap it kept")
        XCTAssertEqual(lastOperation(of: publisher), .stop)
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
            let capture = harness.voiceProcessingEngines.engines.first,
            let publisher = harness.publisherEngines.engines.first
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
        XCTAssertEqual(lastOperation(of: publisher), .start, "the publisher the start built keeps running")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine start").isEmpty)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)
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
        XCTAssertEqual(lastOperation(of: publisher), .stop, "and the publisher")
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
            let capture = harness.voiceProcessingEngines.engines.first,
            let publisher = harness.publisherEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertEqual(capture.calls.last, .start, "the engine that started is not stopped inside the change")
        XCTAssertEqual(lastOperation(of: publisher), .start)
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
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)
        XCTAssertEqual(harness.holdReasons.last, "processing-refused")
        XCTAssertNotEqual(harness.state.processedMicrophoneState, .active)

        harness.hal.currentDefaultOutputID = AudioStateHarness.speakers
        releaseUntilActive(harness)
        XCTAssertTrue(capture.calls.contains(.stop), "the release stops the engine that started")
        XCTAssertEqual(lastOperation(of: publisher), .stop)
        let stop = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-voice-processing-engine stop ")
        let publisherStop = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-publisher-engine stop ")
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
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-publisher-engine stop").isEmpty)

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
            let capture = harness.voiceProcessingEngines.engines.first,
            let publisher = harness.publisherEngines.engines.first
        else {
            return XCTFail("the start did not get as far as the publisher")
        }

        XCTAssertEqual(capture.calls.last, .prepare, "the engine does not start")
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-voice-processing-engine start").isEmpty)
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-source interrupt ").count, 1)
        XCTAssertTrue(harness.lines(withPrefix: "processed-microphone-source refuse ").isEmpty, "no default moved")

        releaseUntilActive(harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "the release stops the kept engine")
        XCTAssertEqual(lastOperation(of: publisher), .stop)
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
        for prefix in [
            "processed-microphone-voice-processing-engine stop ",
            "processed-microphone-publisher-engine stop "
        ] {
            let stopLine = harness.lines(withPrefix: prefix).last
            XCTAssertEqual(stopLine.flatMap { AudioStateHarness.field("reason", of: $0) }, "bluetooth-selection", prefix)
            XCTAssertEqual(stopLine.flatMap { AudioStateHarness.field("gen", of: $0) }, "-", prefix)
        }
        let stopBegin = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-voice-processing-engine stop-begin ")
        let publisherStop = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-publisher-engine stop ")
        let hold = harness.timelineIndex(ofLineWithPrefix: "quiet-window hold reason=input-selection ")
        let write = harness.timelineIndex(ofLineWithPrefix: "default-device-write id=99")
        XCTAssertNotNil(stopBegin)
        XCTAssertNotNil(publisherStop)
        XCTAssertNotNil(hold)
        XCTAssertNotNil(write)
        if let stopBegin, let publisherStop, let hold, let write {
            XCTAssertLessThan(stopBegin, publisherStop)
            XCTAssertLessThan(publisherStop, hold, "both engines stop before the pick's window")
            XCTAssertLessThan(hold, write, "and before the default is written")
        }
        XCTAssertTrue(harness.lines(withPrefix: "picker refuse ").isEmpty)
    }

    // MARK: Engine lifetime

    func testEnginesStoppedWhileAWindowFollowsAreFreedOnlyByAnEvaluationThatAdmitsStarts() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.last,
            let publisher = harness.publisherEngines.engines.last
        else {
            return XCTFail("the engines did not start")
        }
        let engine = harness.state.processedMicrophoneEngineForTesting

        // The picker's stop, then the pick's window.
        select(99, .input, in: harness)
        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap])
        XCTAssertEqual(harness.holdReasons.last, "input-selection")
        XCTAssertTrue(engine.retiredEnginesForTesting.contains { $0 === capture }, "the capture engine is not freed inside the window")
        XCTAssertTrue(engine.retiredEnginesForTesting.contains { $0 === publisher }, "nor the publisher")

        harness.poll()
        XCTAssertTrue(engine.retiredEnginesForTesting.contains { $0 === capture }, "an evaluation the window holds frees nothing")

        for _ in 0..<3 where !engine.retiredEnginesForTesting.isEmpty {
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
        }
        XCTAssertFalse(engine.retiredEnginesForTesting.contains { $0 === capture }, "freed once starts are admitted")
        XCTAssertFalse(engine.retiredEnginesForTesting.contains { $0 === publisher })
    }

    func testQuitStopsTheEnginesAndKeepsThemUntilTheProcessExits() {
        let harness = runningHarness()
        defer { harness.tearDown() }
        guard
            let capture = harness.voiceProcessingEngines.engines.last,
            let publisher = harness.publisherEngines.engines.last
        else {
            return XCTFail("the engines did not start")
        }
        harness.hal.isRunningSomewhereRead = (noErr, 0)

        harness.state.stop()
        harness.settle()

        XCTAssertEqual(Array(capture.calls.suffix(2)), [.stop, .removeTap], "Quit still stops the capture engine")
        XCTAssertEqual(lastOperation(of: publisher), .stop, "and the publisher")
        let kept = ProcessedMicrophoneEngine.enginesKeptUntilExitForTesting
        XCTAssertTrue(kept.contains { $0 === capture }, "no capture engine is freed during Quit's teardown")
        XCTAssertTrue(kept.contains { $0 === publisher }, "nor the publisher")
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
        XCTAssertTrue(harness.publisherEngines.engines.isEmpty, "nor a publisher")
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
