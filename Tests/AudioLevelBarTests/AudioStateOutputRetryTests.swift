import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// How `AudioState` retries a processed microphone start whose output reads
/// no usable format, through the harness: fake engines report 0 Hz, and
/// nothing reaches coreaudiod.
final class AudioStateOutputRetryTests: XCTestCase {
    private var retriesEndedMessage: String {
        localized("The processed microphone stopped trying to start because its output kept reporting no usable audio format. Choose Retry to try again. It also tries again when the output device changes.")
    }

    private let maximum = PublisherOutputRetry.maximumConsecutiveFailures

    /// Launches with processing off, publishes, has every publisher engine
    /// made from then on read its output as 0 Hz, and has a consumer open
    /// the published device, so the first start fails.
    private func unusableOutputHarness(file: StaticString = #filePath, line: UInt = #line) -> AudioStateHarness {
        let harness = AudioStateHarness(processedMicrophone: true)
        harness.launchAndPublish(file: file, line: line)
        harness.publisherEngines.prepare = { $0.reportsNoSampleRate = true }
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        return harness
    }

    /// Lets `count` windows, each with the longest spacing, pass, polling
    /// after each.
    private func passRetries(_ harness: AudioStateHarness, count: Int) {
        for _ in 0..<count {
            harness.advance(by: PublisherOutputRetry.maximumRetryDelay + LifecycleQuietWindow.settle + 0.1)
            harness.poll()
            harness.poll()
        }
    }

    private func captureLines(_ harness: AudioStateHarness, _ operation: String) -> Int {
        harness.lines(withPrefix: "processed-microphone-capture-ioproc \(operation) ").count
    }

    func testAnOutputThatKeepsReadingNoFormatIsRetriedSpacedAndThenNotUntilRetry() {
        let harness = unusableOutputHarness()
        defer { harness.tearDown() }
        XCTAssertEqual(harness.publisherEngines.engines.count, 1, "the first start")
        XCTAssertEqual(harness.holdReasons.last, "processing-invalidated")

        // The first read spaces the next try 2 s, less than the window.
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.poll()
        XCTAssertEqual(harness.publisherEngines.engines.count, 2)

        // The second spaces it 4 s, longer than the window.
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.poll()
        XCTAssertEqual(harness.publisherEngines.engines.count, 2, "the window has passed, the spacing has not")
        harness.advance(by: 1)
        harness.poll()
        XCTAssertEqual(harness.publisherEngines.engines.count, 3)

        passRetries(harness, count: maximum + 2)
        XCTAssertEqual(harness.publisherEngines.engines.count, maximum, "no start after the last read in a row")
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(retriesEndedMessage))
        let giveUps = harness.lines(withPrefix: "processed-microphone-publisher-engine give-up ")
        XCTAssertEqual(giveUps.count, 1)
        XCTAssertEqual(giveUps.first.flatMap { AudioStateHarness.field("id", of: $0) }, "\(AudioStateHarness.speakers)")
        XCTAssertEqual(giveUps.first.flatMap { AudioStateHarness.field("transport", of: $0) }, "builtIn")

        let creates = captureLines(harness, "create")
        let destroys = captureLines(harness, "destroy")
        passRetries(harness, count: 3)
        XCTAssertEqual(harness.publisherEngines.engines.count, maximum)
        XCTAssertEqual(captureLines(harness, "create"), creates, "no start")
        XCTAssertEqual(captureLines(harness, "destroy"), destroys, "and no release of the capture the last start left")
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(retriesEndedMessage))

        harness.state.retryProcessedMicrophone()
        harness.settle()
        XCTAssertEqual(harness.publisherEngines.engines.count, maximum + 1, "the retry starts again at once")
        XCTAssertNotEqual(harness.state.processedMicrophoneState, .failed(retriesEndedMessage))
    }

    func testRetriesThatEndedStartOverWhenTheDefaultOutputChanges() {
        let harness = unusableOutputHarness()
        defer { harness.tearDown() }
        passRetries(harness, count: maximum + 1)
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(retriesEndedMessage))

        harness.moveDefaultOutput(to: AudioStateHarness.usbOutput)
        harness.poll()
        XCTAssertEqual(harness.state.processedMicrophoneState, .starting, "shown as soon as the poll sees it")
        XCTAssertEqual(harness.publisherEngines.engines.count, maximum, "nothing starts inside the window")

        passRetries(harness, count: 1)
        XCTAssertEqual(harness.publisherEngines.engines.count, maximum + 1)
    }

    func testABluetoothInputOverRetriesThatEndedKeepsTheFailureAndItsRetry() {
        let harness = unusableOutputHarness()
        defer { harness.tearDown() }
        passRetries(harness, count: maximum + 1)
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(retriesEndedMessage))
        let engines = harness.publisherEngines.engines.count

        // A Bluetooth microphone becomes the default input; the default output
        // stays, so the retries stay ended. The plan issues nothing until
        // Retry, so the state must keep offering it: a refusal or a starting
        // state shown instead would wait with no way on.
        harness.connectHeadset()
        harness.system.setDefault(AudioStateHarness.headset, for: .input)
        harness.poll()
        XCTAssertEqual(
            harness.state.processedMicrophoneState,
            .failed(retriesEndedMessage),
            "the failure stays over a Bluetooth input"
        )

        harness.system.setDefault(AudioStateHarness.builtInMicrophone, for: .input)
        harness.poll()
        XCTAssertEqual(
            harness.state.processedMicrophoneState,
            .failed(retriesEndedMessage),
            "and after the input comes back"
        )
        passRetries(harness, count: 1)
        XCTAssertEqual(harness.publisherEngines.engines.count, engines, "nothing starts until Retry")
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(retriesEndedMessage))

        harness.state.retryProcessedMicrophone()
        harness.settle()
        XCTAssertEqual(harness.publisherEngines.engines.count, engines + 1, "the retry starts again")
    }

    func testAppleVoiceProcessingEndsItsRetriesTheSameWay() {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: .apple)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.onVoiceProcessingEngineCall { engine, call in
            if call == .loadIONodes {
                engine.outputReportsNoSampleRate = true
            }
        }
        harness.setPublishedDeviceInUse(true)
        harness.settle()

        passRetries(harness, count: maximum + 2)
        XCTAssertEqual(harness.voiceProcessingEngines.engines.count, maximum)
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(retriesEndedMessage))
        XCTAssertEqual(harness.state.microphoneProcessingMode, .apple, "not a failure of the mode")
        let giveUps = harness.lines(withPrefix: "processed-microphone-publisher-engine give-up ")
        XCTAssertEqual(giveUps.count, 1)
        XCTAssertEqual(giveUps.first.flatMap { AudioStateHarness.field("id", of: $0) }, "\(AudioStateHarness.speakers)")
    }
}
