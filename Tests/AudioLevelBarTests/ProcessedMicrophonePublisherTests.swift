import AVFoundation
import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// The processed microphone's publisher engine, built through a fake engine
/// that opens no device: it is bound to its output and reads the binding back
/// before anything reads that output's format or connects to it, and every
/// engine that raises goes back to the caller, neither stopped nor freed,
/// with the step and the exception.
final class ProcessedMicrophonePublisherTests: XCTestCase {
    private let output: AudioDeviceID = 600

    override func tearDown() {
        HALLifecycleLog.observer = nil
        super.tearDown()
    }

    func testTheOutputIsBoundAndReadBackBeforeItsFormatIsReadOrAnythingIsConnected() throws {
        let fake = FakePublisherEngine()
        let engine = makeEngine(fake)

        let publisher = try engine.makePublisher(
            format: Self.monoFormat,
            ringBuffer: try XCTUnwrap(ProcessedMicrophoneRingBuffer(format: Self.monoFormat, duration: 0.25)),
            output: builtInOutput,
            generation: 3
        )

        XCTAssertTrue(publisher.engine === fake)
        XCTAssertEqual(
            fake.calls,
            [
                .loadOutputNode,
                .bindOutput(output),
                .readBoundOutput,
                .readOutputFormat,
                .attachAndConnect,
                .readBoundOutput,
                .prepare,
                .readBoundOutput,
                .readBoundOutput,
                .start,
                .readBoundOutput
            ],
            "bound, read back and format-checked first; the prepare and the start are each between their two log lines"
        )
    }

    func testThePrepareIsBetweenItsOwnLinesBeforeTheStartsLines() throws {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-engine ")
        let engine = makeEngine(FakePublisherEngine())

        try build(engine)

        XCTAssertEqual(
            lines.values,
            [
                "processed-microphone-publisher-engine prepare-begin id=\(output) transport=builtIn gen=3",
                "processed-microphone-publisher-engine prepare id=\(output) transport=builtIn status=0 gen=3",
                "processed-microphone-publisher-engine start-begin id=\(output) transport=builtIn gen=3",
                "processed-microphone-publisher-engine start id=\(output) transport=builtIn status=0 gen=3"
            ]
        )
    }

    func testAPrepareThatRaisesIsLoggedAsFailedAndNothingStarts() {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-engine ")
        let fake = FakePublisherEngine()
        fake.raisesAt = .prepare
        let engine = makeEngine(fake)

        XCTAssertThrowsError(try build(engine)) { error in
            guard let kept = error as? ProcessedMicrophoneEngine.PublisherStartInterrupted, let raised = kept.raised else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(kept.engine === fake, "an engine that raised goes to the caller rather than being freed")
            XCTAssertFalse(kept.started)
            XCTAssertEqual(raised.step, localized("Starting processed microphone output"))
            XCTAssertTrue(raised.detail.contains("raised by the fake engine"), raised.detail)
        }
        XCTAssertFalse(fake.calls.contains(.start))
        XCTAssertEqual(
            lines.values,
            [
                "processed-microphone-publisher-engine prepare-begin id=\(output) transport=builtIn gen=3",
                "processed-microphone-publisher-engine prepare id=\(output) transport=builtIn status=\(kAudioHardwareUnspecifiedError) gen=3"
            ]
        )
    }

    func testAnOutputBoundElsewhereIsNeitherReadNorStarted() throws {
        let fake = FakePublisherEngine()
        fake.readBack = 601
        let engine = makeEngine(fake)

        XCTAssertThrowsError(try build(engine)) { error in
            guard case let .operationFailed(step, _)? = error as? ProcessedMicrophoneEngineError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(step, localized("Selecting the processed microphone output device"))
        }
        XCTAssertEqual(fake.calls, [.loadOutputNode, .bindOutput(output), .readBoundOutput])
    }

    func testAnOutputWithoutAUsableFormatIsNeitherConnectedNorStarted() throws {
        let fake = FakePublisherEngine()
        fake.format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        fake.reportsNoSampleRate = true
        let engine = makeEngine(fake)

        XCTAssertThrowsError(try build(engine)) { error in
            guard case .outputUnavailable? = error as? ProcessedMicrophoneEngineError else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(fake.calls, [.loadOutputNode, .bindOutput(output), .readBoundOutput, .readOutputFormat])
    }

    func testAnExceptionRaisedWhileBindingIsThrownAsAFailureToSelectTheOutput() {
        let fake = FakePublisherEngine()
        fake.raisesAt = .bindOutput(output)
        let engine = makeEngine(fake)

        XCTAssertThrowsError(try build(engine)) { error in
            guard let kept = error as? ProcessedMicrophoneEngine.PublisherStartInterrupted, let raised = kept.raised else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(raised.step, localized("Selecting the processed microphone output device"))
            XCTAssertTrue(raised.detail.contains("raised by the fake engine"), raised.detail)
        }
        XCTAssertEqual(fake.calls, [.loadOutputNode, .bindOutput(output)], "nothing after the call that raised")
    }

    func testAnExceptionRaisedByTheStartIsThrownAndTheEngineIsKeptUnstopped() {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-engine ")
        let fake = FakePublisherEngine()
        fake.raisesAt = .start
        let engine = makeEngine(fake)

        XCTAssertThrowsError(try build(engine)) { error in
            guard let kept = error as? ProcessedMicrophoneEngine.PublisherStartInterrupted, let raised = kept.raised else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(kept.engine === fake)
            XCTAssertTrue(kept.started, "its start was issued")
            XCTAssertNotNil(kept.sourceNode)
            XCTAssertEqual(raised.step, localized("Starting processed microphone output"))
            XCTAssertTrue(raised.detail.contains("raised by the fake engine"), raised.detail)
        }
        XCTAssertEqual(
            Array(fake.calls.drop { $0 != .start }),
            [.start, .readBoundOutput],
            "the engine whose start raised is not stopped while AVFAudio rebinds it"
        )
        XCTAssertTrue(engine.retiredEnginesForTesting.isEmpty, "nor freed: the caller keeps it")
        XCTAssertEqual(
            lines.values.map { $0.split(separator: " ").prefix(2).joined(separator: " ") },
            [
                "processed-microphone-publisher-engine prepare-begin",
                "processed-microphone-publisher-engine prepare",
                "processed-microphone-publisher-engine start-begin",
                "processed-microphone-publisher-engine start"
            ]
        )
        XCTAssertTrue(
            lines.values[3].contains("status=\(kAudioHardwareUnspecifiedError)"),
            "a start that raised is logged as failed: \(lines.values[3])"
        )
    }

    // MARK: A start that may no longer proceed

    func testAStartThatMayNotProceedBeforeThePrepareKeepsTheEngineForTheCaller() throws {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-engine ")
        let fake = FakePublisherEngine()
        let engine = makeEngine(fake)
        var proceed = true
        // A quiet window arms while the output's format is read.
        fake.onCall = { call in
            if call == .readOutputFormat {
                proceed = false
            }
        }

        XCTAssertThrowsError(try build(engine, mayProceed: { proceed })) { error in
            guard let kept = error as? ProcessedMicrophoneEngine.PublisherStartInterrupted else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(kept.engine === fake, "the engine goes to the caller, which keeps it")
            XCTAssertFalse(kept.started)
        }
        XCTAssertFalse(fake.calls.contains(.prepare), "no prepare after the check")
        XCTAssertFalse(fake.calls.contains(.start))
        XCTAssertFalse(fake.calls.contains(.stop), "and nothing is stopped inside the window")
        XCTAssertEqual(lines.values, [])
        XCTAssertTrue(engine.retiredEnginesForTesting.isEmpty)
    }

    func testAStartThatMayNotProceedAfterThePrepareDoesNotStart() throws {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-engine ")
        let fake = FakePublisherEngine()
        let engine = makeEngine(fake)
        var proceed = true
        fake.onCall = { call in
            if call == .prepare {
                proceed = false
            }
        }

        XCTAssertThrowsError(try build(engine, mayProceed: { proceed })) { error in
            guard let kept = error as? ProcessedMicrophoneEngine.PublisherStartInterrupted else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(kept.engine === fake)
            XCTAssertFalse(kept.started)
            XCTAssertNotNil(kept.sourceNode, "the source node it attached goes with it")
        }
        XCTAssertFalse(fake.calls.contains(.start))
        XCTAssertFalse(fake.calls.contains(.stop))
        XCTAssertEqual(
            lines.values.map { $0.split(separator: " ").prefix(2).joined(separator: " ") },
            ["processed-microphone-publisher-engine prepare-begin", "processed-microphone-publisher-engine prepare"],
            "no start-begin follows the check"
        )
    }

    func testAFailedStartThatMayNotProceedIsNotStoppedInsideTheWindow() throws {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-engine ")
        let fake = FakePublisherEngine()
        fake.startError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareNotRunningError))
        let engine = makeEngine(fake)
        var proceed = true
        fake.onCall = { call in
            if call == .start {
                proceed = false
            }
        }

        XCTAssertThrowsError(try build(engine, mayProceed: { proceed })) { error in
            guard let kept = error as? ProcessedMicrophoneEngine.PublisherStartInterrupted else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(kept.started, "its start was issued")
        }
        XCTAssertFalse(fake.calls.contains(.stop), "the stop waits for the release after the window")
        XCTAssertTrue(lines.values.filter { $0.contains(" stop") }.isEmpty)
    }

    func testAnOutputThatIsNotBuiltInIsReadAgainBeforeTheStart() {
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(AudioDeviceTransportInfo(transport: .bluetooth), for: output)
        let fake = FakePublisherEngine()
        let engine = makeEngine(fake, hal: hal)

        XCTAssertThrowsError(
            try engine.makePublisher(
                format: Self.monoFormat,
                ringBuffer: XCTUnwrap(ProcessedMicrophoneRingBuffer(format: Self.monoFormat, duration: 0.25)),
                output: PublisherOutput(
                    deviceID: output,
                    transport: "usb",
                    info: AudioDeviceTransportInfo(transport: .usb)
                ),
                generation: 3
            )
        ) { error in
            guard case .outputUnavailable? = error as? ProcessedMicrophoneEngineError else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertFalse(fake.calls.contains(.start), "an output that became Bluetooth is not started")
        XCTAssertFalse(
            fake.calls.contains(.prepare),
            "nor prepared, so no IOProc is created on it and nothing is left to stop"
        )
    }

    func testAListedOutputWhoseTransportWasNotReadIsWaitedForRatherThanRefused() {
        let hal = FakeHALLifecycleCalls()
        let headset: AudioDeviceID = 70
        let usbOutput: AudioDeviceID = 80
        hal.currentDefaultOutputID = headset
        hal.setTransportInfo(AudioDeviceTransportInfo(transport: .bluetooth), for: headset)
        func listed(usbTransport: AudioDeviceTransport?) -> [AudioDevice] {
            [
                AudioDevice(id: headset, name: "Headset", uid: "headset", inputChannelCount: 1, outputChannelCount: 2, transport: .bluetooth),
                AudioDevice(id: usbOutput, name: "USB", uid: "usb", inputChannelCount: 0, outputChannelCount: 2, transport: usbTransport)
            ]
        }

        guard case .refused(.outputsNotRead, _, _) = PublisherOutputReading.read(hal, listedOutputs: listed(usbTransport: nil)) else {
            return XCTFail("an unread transport is a read to wait out")
        }
        guard case .refused(.noNonBluetoothOutput, _, _) = PublisherOutputReading.read(hal, listedOutputs: listed(usbTransport: .unknown)) else {
            return XCTFail("an unclassified transport is refused")
        }
        XCTAssertEqual(listed(usbTransport: nil)[1].transport, .unknown, "the picker still shows an icon for it")
    }

    // MARK: Helpers

    private static let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private var builtInOutput: PublisherOutput {
        PublisherOutput(deviceID: output, transport: "builtIn", info: AudioDeviceTransportInfo(transport: .builtIn))
    }

    private func makeEngine(
        _ fake: FakePublisherEngine,
        hal: FakeHALLifecycleCalls = FakeHALLifecycleCalls()
    ) -> ProcessedMicrophoneEngine {
        ProcessedMicrophoneEngine(
            halCalls: hal,
            holdGeneration: LifecycleHoldGeneration(),
            makePublisherEngine: { fake },
            makeVoiceProcessingEngine: { FakeVoiceProcessingEngine() }
        )
    }

    private func build(_ engine: ProcessedMicrophoneEngine, mayProceed: () -> Bool = { true }) throws {
        _ = try engine.makePublisher(
            format: Self.monoFormat,
            ringBuffer: XCTUnwrap(ProcessedMicrophoneRingBuffer(format: Self.monoFormat, duration: 0.25)),
            output: builtInOutput,
            generation: 3,
            mayProceed: mayProceed
        )
    }
}

/// A publisher engine that records its calls and opens no device. It can
/// read back another device than the one it was bound to, report an output
/// with no sample rate, or raise an Objective-C exception at a chosen call.
final class FakePublisherEngine: ProcessedMicrophonePublisherEngine {
    enum Call: Equatable {
        case loadOutputNode
        case bindOutput(AudioDeviceID)
        case readBoundOutput
        case readOutputFormat
        case attachAndConnect
        case prepare
        case start
        case stop
    }

    private(set) var calls: [Call] = []
    /// What `boundOutputDeviceID` reads; the bound device when nil.
    var readBack: AudioDeviceID?
    var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    /// Whether the output format reads as 0 Hz, as a device being
    /// reconfigured does.
    var reportsNoSampleRate = false
    var raisesAt: Call?
    /// Runs inside each call, after recording it and before it raises or
    /// returns, where a test arms a quiet window at that moment.
    var onCall: ((Call) -> Void)?
    let notificationObject: AnyObject = NSObject()
    private var bound = AudioDeviceID(kAudioObjectUnknown)

    private func note(_ call: Call) {
        calls.append(call)
        onCall?(call)
        if call == raisesAt {
            NSException(
                name: .internalInconsistencyException,
                reason: "raised by the fake engine",
                userInfo: nil
            ).raise()
        }
    }

    func loadOutputNode() {
        note(.loadOutputNode)
    }

    func bindOutput(to deviceID: AudioDeviceID) throws {
        note(.bindOutput(deviceID))
        bound = deviceID
    }

    var boundOutputDeviceID: AudioDeviceID {
        note(.readBoundOutput)
        return readBack ?? bound
    }

    func outputFormat() -> AVAudioFormat {
        note(.readOutputFormat)
        guard reportsNoSampleRate else {
            return format
        }
        // An AVAudioFormat cannot be made with 0 Hz; one without a layout
        // reads as 0 Hz and no channels.
        return AVAudioFormat()
    }

    func attachAndConnect(_ sourceNode: AVAudioSourceNode, format: AVAudioFormat) {
        note(.attachAndConnect)
    }

    func prepare() {
        note(.prepare)
    }

    /// What `start()` throws, if anything, once it has recorded the call.
    var startError: Error?

    func start() throws {
        note(.start)
        if let startError {
            throw startError
        }
    }

    func stop() {
        note(.stop)
    }
}
