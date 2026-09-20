import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// How `AudioState` retries a processed microphone capture whose input only
/// the read made as it was opened refused, through the harness: the fake
/// HAL's read of the input fails on the capture's queue alone, and nothing
/// reaches coreaudiod.
final class AudioStateCaptureInputRetryTests: XCTestCase {
    private static let microphone = AudioStateHarness.builtInMicrophone
    private let microphone = AudioStateCaptureInputRetryTests.microphone
    private let maximum = CaptureInputRetry.maximumConsecutiveFailures

    /// The default input as an aggregate device whose members all resolve.
    private static let resolved = AudioDeviceTransportInfo(
        transport: .aggregate,
        activeSubDeviceTransports: [.builtIn],
        fullSubDeviceTransports: [.builtIn, .usb]
    )
    /// The same device read with a member that could not be resolved.
    private static let unresolved = AudioDeviceTransportInfo(
        transport: .aggregate,
        activeSubDeviceTransports: [.builtIn],
        fullSubDeviceTransports: [.builtIn, nil]
    )
    /// The same device read with a Bluetooth member.
    private static let withBluetoothMember = AudioDeviceTransportInfo(
        transport: .aggregate,
        activeSubDeviceTransports: [.builtIn],
        fullSubDeviceTransports: [.builtIn, .bluetooth]
    )

    private var readsFailedMessage: String {
        localized("The processed microphone stopped trying to start because the input device’s connection type, or the devices that make up an aggregate input, could not be read as it was opened. Choose Retry to try again.")
    }

    /// What the capture's own reads of the input return, set by a test.
    private final class CaptureRead {
        var info: AudioDeviceTransportInfo?

        init(_ info: AudioDeviceTransportInfo?) {
            self.info = info
        }
    }

    /// Launches with the default input an aggregate device the poll and the
    /// meter resolve, and publishes. From then on the capture's own reads of
    /// that input, made on its lifecycle queue as it opens it, return what
    /// `captureRead` holds.
    private func aggregateInputHarness(
        captureRead: CaptureRead,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioStateHarness {
        let harness = AudioStateHarness(processedMicrophone: true)
        harness.system.setPolledTransportInfo(Self.resolved, for: microphone)
        harness.hal.setTransportInfo(Self.resolved, for: microphone)
        harness.launchAndPublish(file: file, line: line)
        let captureQueue = harness.state.lifecycleQueuesForTesting.processedMicrophoneCapture.label
        harness.hal.onRead = { [unowned harness] read in
            guard read == .transportInfo(Self.microphone) else {
                return
            }
            let onCaptureQueue = String(cString: __dispatch_queue_get_label(nil)) == captureQueue
            harness.hal.setTransportInfo(onCaptureQueue ? captureRead.info : Self.resolved, for: Self.microphone)
        }
        return harness
    }

    private func refusals(_ harness: AudioStateHarness) -> Int {
        harness.lines(withPrefix: "processed-microphone-capture-ioproc refuse id=\(microphone) ").count
    }

    private func giveUps(_ harness: AudioStateHarness) -> [String] {
        harness.lines(withPrefix: "processed-microphone-capture-ioproc give-up ")
    }

    private func pass(_ harness: AudioStateHarness, _ seconds: TimeInterval) {
        harness.advance(by: seconds)
        harness.poll()
        harness.poll()
    }

    /// Lets `count` windows, each with the longest spacing, pass.
    private func passRetries(_ harness: AudioStateHarness, count: Int) {
        for _ in 0..<count {
            pass(harness, CaptureInputRetry.maximumRetryDelay + LifecycleQuietWindow.settle + 0.1)
        }
    }

    func testAnInputOnlyTheOpenTimeReadRefusedIsRetriedWithTheMetersSpacingAndEndsFailedWithRetry() {
        // An aggregate member that read could not resolve, and a transport it
        // could not read at all.
        for failedRead in [Self.unresolved, nil] {
            let captureRead = CaptureRead(failedRead)
            let harness = aggregateInputHarness(captureRead: captureRead)
            defer { harness.tearDown() }

            harness.setPublishedDeviceInUse(true)
            harness.settle()
            XCTAssertEqual(refusals(harness), 1, "the first start")
            XCTAssertEqual(harness.holdReasons.last, "processing-refused", "held like any read that failed")
            XCTAssertEqual(
                harness.state.processedMicrophoneState,
                .starting,
                "not shown, or latched, as a Bluetooth refusal: the poll resolves every member"
            )

            // The first failed read spaces the next try 2 s, less than the window.
            pass(harness, LifecycleQuietWindow.settle + 0.1)
            XCTAssertEqual(refusals(harness), 2)

            // The second spaces it 4 s, longer than the window.
            pass(harness, LifecycleQuietWindow.settle + 0.1)
            XCTAssertEqual(refusals(harness), 2, "the window has passed, the spacing has not")
            pass(harness, 1)
            XCTAssertEqual(refusals(harness), 3)

            // The third, 8 s.
            pass(harness, LifecycleQuietWindow.settle + 0.1)
            pass(harness, 4)
            XCTAssertEqual(refusals(harness), 3, "7.2 s after the third failed read")
            pass(harness, 1)
            XCTAssertEqual(refusals(harness), 4)

            passRetries(harness, count: maximum + 2)
            XCTAssertEqual(refusals(harness), maximum, "no start after the last failed read in a row")
            XCTAssertEqual(
                harness.holdReasons.filter { $0 == "processing-refused" }.count,
                maximum,
                "each refusal holds the window"
            )
            XCTAssertEqual(harness.state.processedMicrophoneState, .failed(readsFailedMessage), "failed, which offers Retry")
            XCTAssertEqual(giveUps(harness).count, 1, "\(giveUps(harness))")
            XCTAssertEqual(giveUps(harness).first.flatMap { AudioStateHarness.field("id", of: $0) }, "\(microphone)")
            XCTAssertEqual(
                giveUps(harness).first.flatMap { AudioStateHarness.field("transport", of: $0) },
                "aggregate[builtIn|builtIn,usb]",
                "the class as the poll shows it"
            )

            passRetries(harness, count: 3)
            XCTAssertEqual(refusals(harness), maximum, "nothing more until Retry")
            XCTAssertEqual(harness.state.processedMicrophoneState, .failed(readsFailedMessage))

            // Retry starts again at once, and a read that succeeds recovers.
            captureRead.info = Self.resolved
            harness.state.retryProcessedMicrophone()
            harness.settle()
            harness.poll()
            XCTAssertEqual(harness.state.processedMicrophoneState, .active)
            XCTAssertEqual(refusals(harness), maximum)
        }
    }

    func testALaterOpenThatSucceedsRecoversAndStartsTheCountOver() {
        let captureRead = CaptureRead(Self.unresolved)
        let harness = aggregateInputHarness(captureRead: captureRead)
        defer { harness.tearDown() }
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        pass(harness, LifecycleQuietWindow.settle + 0.1)
        pass(harness, CaptureInputRetry.maximumRetryDelay)
        XCTAssertEqual(refusals(harness), 3)

        // The read resolves every member again.
        captureRead.info = Self.resolved
        passRetries(harness, count: 1)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active, "it starts by itself, with no Retry")
        XCTAssertEqual(refusals(harness), 3)
        XCTAssertEqual(giveUps(harness), [])

        // The consuming app lets go and comes back, and the read fails again:
        // the first failed read in a row, spaced 2 s, not the fourth, spaced 8.
        harness.setPublishedDeviceInUse(false)
        harness.settle()
        pass(harness, 3.1)
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
        captureRead.info = Self.unresolved
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(refusals(harness), 4)
        pass(harness, LifecycleQuietWindow.settle + 0.1)
        XCTAssertEqual(refusals(harness), 5, "the next try follows the window alone")
    }

    func testARefusalThePollItselfMakesStandsAsARefusal() {
        let captureRead = CaptureRead(Self.resolved)
        let harness = aggregateInputHarness(captureRead: captureRead)
        defer { harness.tearDown() }
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)

        // The poll's own read no longer resolves a member of the aggregate.
        harness.system.setPolledTransportInfo(Self.unresolved, for: microphone)
        harness.poll()
        harness.poll()
        XCTAssertEqual(harness.state.processedMicrophoneState, .refused(.bluetoothInput, published: true))

        let creates = harness.lines(withPrefix: "processed-microphone-capture-ioproc create-begin ").count
        passRetries(harness, count: maximum + 1)
        XCTAssertEqual(
            harness.state.processedMicrophoneState,
            .refused(.bluetoothInput, published: true),
            "a refusal with no Retry, however long it lasts"
        )
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-capture-ioproc create-begin ").count, creates)
        XCTAssertEqual(refusals(harness), 0, "no start is issued for it")
        XCTAssertEqual(giveUps(harness), [])

        // It clears by itself once the poll resolves the member again.
        harness.system.setPolledTransportInfo(Self.resolved, for: microphone)
        pass(harness, 0.25)
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
    }

    func testABluetoothMemberTheOpenTimeReadFindsStillLatchesAsARefusal() {
        let captureRead = CaptureRead(Self.withBluetoothMember)
        let harness = aggregateInputHarness(captureRead: captureRead)
        defer { harness.tearDown() }
        harness.setPublishedDeviceInUse(true)
        harness.settle()

        XCTAssertEqual(refusals(harness), 1)
        XCTAssertEqual(harness.state.processedMicrophoneState, .refused(.bluetoothInput, published: true))
        XCTAssertFalse(harness.holdReasons.contains("processing-refused"))

        passRetries(harness, count: 3)
        XCTAssertEqual(refusals(harness), 1, "latched: not tried again while the poll shows the same input")
        XCTAssertEqual(harness.state.processedMicrophoneState, .refused(.bluetoothInput, published: true))
        XCTAssertEqual(giveUps(harness), [])
    }
}
