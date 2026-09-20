import AppKit
import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// How `AudioState` lets a microphone meter that gave up start again, through
/// the harness: the fake HAL's `AudioDeviceStart`, or its read of the input's
/// transport, fails until the test says otherwise, and nothing reaches
/// coreaudiod.
final class AudioStateMeterRetryTests: XCTestCase {
    private let microphone = AudioStateHarness.builtInMicrophone
    private let maximum = MeterSession.maximumStartAttempts

    /// What the panel shows for an `AudioDeviceStart` that failed.
    private var startFailedMessage: String {
        MicrophoneMeterError.operationFailed(
            localized("Starting microphone level monitoring"),
            kAudioHardwareUnspecifiedError
        ).localizedDescription
    }

    private func starts(_ harness: AudioStateHarness) -> Int {
        harness.hal.lifecycleCalls.filter { $0 == .start(microphone) }.count
    }

    private func giveUps(_ harness: AudioStateHarness) -> [String] {
        harness.lines(withPrefix: "microphone-ioproc give-up ")
    }

    /// Lets the longest spacing pass `count` times, with a poll after each.
    /// The first one after launch outlasts the launch window too.
    private func passSpacings(_ harness: AudioStateHarness, count: Int) {
        for _ in 0..<count {
            harness.advance(by: MeterSession.maximumRetryDelay + 0.1)
            harness.poll()
        }
    }

    /// Launches with every `AudioDeviceStart` failing, and lets the meter's
    /// starts on the built-in microphone fail until it gives up.
    private func givenUpHarness(
        processedMicrophone: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioStateHarness {
        let harness = AudioStateHarness(processedMicrophone: processedMicrophone)
        harness.hal.startStatus = kAudioHardwareUnspecifiedError
        harness.launch()
        passSpacings(harness, count: maximum)
        XCTAssertEqual(starts(harness), maximum, file: file, line: line)
        XCTAssertTrue(harness.state.microphoneMeterGaveUp, file: file, line: line)
        return harness
    }

    func testAMeterWhoseStartsKeepFailingGivesUpOnceAndIssuesNothingUntilRetryStartsItAfterTheWindow() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.hal.startStatus = kAudioHardwareUnspecifiedError
        harness.launch()

        passSpacings(harness, count: maximum - 1)
        XCTAssertEqual(starts(harness), maximum - 1)
        XCTAssertEqual(harness.state.microphoneError, startFailedMessage, "each failed start shows its error")
        XCTAssertFalse(harness.state.microphoneMeterGaveUp, "no Retry while the meter still retries by itself")
        XCTAssertEqual(giveUps(harness), [])

        passSpacings(harness, count: 1)
        XCTAssertEqual(starts(harness), maximum)
        XCTAssertTrue(harness.state.microphoneMeterGaveUp, "the panel offers Retry")
        XCTAssertEqual(harness.state.microphoneError, startFailedMessage)
        XCTAssertEqual(harness.state.microphoneDisplay, .starting, "the menu bar shows --")
        XCTAssertEqual(giveUps(harness).count, 1, "\(giveUps(harness))")
        XCTAssertEqual(giveUps(harness).first.flatMap { AudioStateHarness.field("id", of: $0) }, "\(microphone)")
        XCTAssertEqual(
            giveUps(harness).first.flatMap { AudioStateHarness.field("transport", of: $0) },
            "builtIn",
            "the class as the poll shows it"
        )
        XCTAssertEqual(
            harness.hal.lifecycleCalls.filter { $0 == .destroyIOProc(microphone) }.count,
            harness.hal.lifecycleCalls.filter { $0 == .createIOProc(microphone) }.count,
            "each failed start released what it created, so a meter that gave up holds nothing open"
        )

        // The input stays the default: neither polls, nor a window that arms
        // and releases, nor a device-list notification, nor a wake is a retry.
        let callsAtGiveUp = harness.hal.calls.count
        passSpacings(harness, count: 3)
        harness.fireSystemNotification(.defaultInput)
        harness.settle()
        XCTAssertEqual(harness.holdReasons.last, "hal-notification")
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.poll()
        harness.fireSystemNotification(.devices)
        harness.settle()
        harness.powerNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        harness.settle()
        XCTAssertEqual(harness.lines(withPrefix: "power did-wake ").count, 1)
        // Whatever made the starts fail is over, and nothing notices.
        harness.hal.startStatus = noErr
        passSpacings(harness, count: 2)
        XCTAssertEqual(harness.lifecycleCalls(after: callsAtGiveUp), [], "nothing is issued for a meter that gave up")
        XCTAssertTrue(harness.state.microphoneMeterGaveUp)
        XCTAssertEqual(harness.state.microphoneError, startFailedMessage)
        XCTAssertEqual(giveUps(harness).count, 1, "written once")

        // Retry while a quiet window holds: it issues nothing itself, and the
        // evaluation it asks for holds the start like any other.
        harness.fireSystemNotification(.defaultOutput)
        harness.settle()
        harness.state.retryMicrophoneMeter()
        harness.settle()
        XCTAssertNil(harness.state.microphoneError, "Retry clears the error")
        XCTAssertFalse(harness.state.microphoneMeterGaveUp, "and is no longer offered")
        XCTAssertEqual(harness.state.microphoneDisplay, .starting)
        XCTAssertEqual(harness.lifecycleCalls(after: callsAtGiveUp), [], "the window holds the start")

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(
            harness.lifecycleCalls(after: callsAtGiveUp),
            [.createIOProc(microphone), .start(microphone)],
            "one start, at the release"
        )
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertNil(harness.state.microphoneError)

        passSpacings(harness, count: 2)
        XCTAssertEqual(
            harness.lifecycleCalls(after: callsAtGiveUp),
            [.createIOProc(microphone), .start(microphone)],
            "and no other"
        )
        XCTAssertEqual(giveUps(harness).count, 1)
    }

    func testRetryStartsTheCountOverSoAMeterThatKeepsFailingIsSpacedAndGivesUpAgain() {
        let harness = givenUpHarness()
        defer { harness.tearDown() }

        // No window holds, so the evaluation Retry asks for issues the start.
        harness.state.retryMicrophoneMeter()
        harness.settle()
        XCTAssertEqual(starts(harness), maximum + 1)
        XCTAssertEqual(harness.state.microphoneError, startFailedMessage, "it failed again")
        XCTAssertFalse(harness.state.microphoneMeterGaveUp, "the first failure of a new count")

        harness.advance(by: 1.9)
        harness.poll()
        XCTAssertEqual(starts(harness), maximum + 1, "spaced 2 s, as after a first failure")
        harness.advance(by: 0.2)
        harness.poll()
        XCTAssertEqual(starts(harness), maximum + 2)

        passSpacings(harness, count: maximum - 3)
        XCTAssertEqual(starts(harness), 2 * maximum - 1)
        XCTAssertFalse(harness.state.microphoneMeterGaveUp)
        XCTAssertEqual(giveUps(harness).count, 1)

        passSpacings(harness, count: 1)
        XCTAssertEqual(starts(harness), 2 * maximum)
        XCTAssertTrue(harness.state.microphoneMeterGaveUp, "the eighth failure since Retry")
        XCTAssertEqual(giveUps(harness).count, 2, "once for each time it gave up")

        passSpacings(harness, count: 2)
        XCTAssertEqual(starts(harness), 2 * maximum)
    }

    func testAStartThatSucceedsAfterRetryStartsTheCountOver() {
        let harness = givenUpHarness()
        defer { harness.tearDown() }
        harness.hal.startStatus = noErr
        harness.state.retryMicrophoneMeter()
        harness.settle()
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertNil(harness.state.microphoneError)
        XCTAssertFalse(harness.state.microphoneMeterGaveUp)

        // The device then reconfigures under the meter, and its starts fail
        // again: the first failure counts as the first.
        harness.hal.startStatus = kAudioHardwareUnspecifiedError
        harness.hal.fireListener(deviceID: microphone, selector: kAudioDevicePropertyDeviceIsAlive)
        harness.settle()
        XCTAssertEqual(harness.holdReasons.last, "meter-invalidated")
        passSpacings(harness, count: maximum - 1)
        XCTAssertEqual(starts(harness), 2 * maximum)
        XCTAssertFalse(harness.state.microphoneMeterGaveUp, "seven failures since the start that succeeded")
        XCTAssertEqual(giveUps(harness).count, 1)

        passSpacings(harness, count: 1)
        XCTAssertEqual(starts(harness), 2 * maximum + 1)
        XCTAssertTrue(harness.state.microphoneMeterGaveUp)
        XCTAssertEqual(giveUps(harness).count, 2)
    }

    func testAMeterThatCouldNotReadTheTransportGivesUpOnceAndRetryWaitsForTheWindowItsLastRefusalArmed() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        // The meter's own read of the device's transport, as it opens it,
        // fails every time, while the poll reads it.
        harness.hal.setTransportInfo(nil, for: microphone)
        harness.launch()
        for _ in 0..<maximum {
            harness.advance(by: MeterSession.maximumRetryDelay + LifecycleQuietWindow.settle)
            harness.poll()
        }
        XCTAssertEqual(harness.lines(withPrefix: "microphone-ioproc refuse id=\(microphone) ").count, maximum)
        XCTAssertTrue(harness.state.microphoneMeterGaveUp)
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.microphoneTransportUnreadMessage)
        XCTAssertEqual(giveUps(harness).count, 1, "\(giveUps(harness))")
        XCTAssertEqual(
            giveUps(harness).first.flatMap { AudioStateHarness.field("transport", of: $0) },
            "builtIn",
            "the class as the poll shows it, not what the open read"
        )

        // The read works again. The last refusal armed a window, and the
        // start Retry asks for waits for its release.
        harness.hal.setTransportInfo(AudioDeviceTransportInfo(transport: .builtIn), for: microphone)
        XCTAssertEqual(harness.holdReasons.last, "meter-refused")
        harness.state.retryMicrophoneMeter()
        harness.settle()
        XCTAssertNil(harness.state.microphoneError)
        XCTAssertFalse(harness.state.microphoneMeterGaveUp)
        XCTAssertEqual(harness.hal.lifecycleCalls, [], "nothing is opened inside the window")

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(harness.hal.lifecycleCalls, [.createIOProc(microphone), .start(microphone)])
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertEqual(giveUps(harness).count, 1)
    }

    func testRetryIsIgnoredWhileTheMeterStillRetriesByItself() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.hal.startStatus = kAudioHardwareUnspecifiedError
        harness.launch()
        passSpacings(harness, count: 3)
        XCTAssertEqual(starts(harness), 3)
        let calls = harness.hal.calls.count

        // The fourth start is due 8 s after the third failed.
        harness.advance(by: 1)
        harness.state.retryMicrophoneMeter()
        harness.settle()
        harness.poll()
        XCTAssertEqual(harness.lifecycleCalls(after: calls), [], "the next start still waits for its spacing")
        XCTAssertEqual(harness.state.microphoneError, startFailedMessage, "and the error stays")

        harness.advance(by: MeterSession.maximumRetryDelay - 1 + 0.1)
        harness.poll()
        XCTAssertEqual(starts(harness), 4)

        // The count was not started over either: it gives up at the eighth.
        passSpacings(harness, count: maximum - 4)
        XCTAssertEqual(starts(harness), maximum)
        XCTAssertTrue(harness.state.microphoneMeterGaveUp)
        passSpacings(harness, count: 1)
        XCTAssertEqual(starts(harness), maximum)
    }

    func testRetryIsIgnoredWhileAStartHasNotReportedBackStalledOrNot() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.hal.startStatus = kAudioHardwareUnspecifiedError
        harness.launch()
        passSpacings(harness, count: 2)
        let target = microphone
        harness.holds.hold { point, _ in point == .hal(.start(target)) }
        passSpacings(harness, count: 1)
        XCTAssertEqual(harness.holds.entered, [.hal(.start(microphone))])
        let calls = harness.hal.calls.count

        harness.state.retryMicrophoneMeter()
        harness.settle()
        XCTAssertEqual(harness.state.microphoneError, startFailedMessage, "the second failure's error stays")
        XCTAssertEqual(harness.lifecycleCalls(after: calls), [])

        harness.advance(by: MeterSession.startTimeout)
        harness.evaluate()
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.microphoneStallMessage)
        XCTAssertFalse(harness.state.microphoneMeterGaveUp, "a stall is not the meter's to retry")
        harness.state.retryMicrophoneMeter()
        harness.settle()
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.microphoneStallMessage)
        XCTAssertEqual(harness.lifecycleCalls(after: calls), [])

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertEqual(
            harness.lifecycleCalls(after: calls),
            [.destroyIOProc(microphone)],
            "the held start failed and released what it created; nothing was queued behind it"
        )
        XCTAssertEqual(harness.state.microphoneError, startFailedMessage)
        XCTAssertEqual(starts(harness), 3)
    }

    func testRetryIsIgnoredOnceQuitWasRequested() {
        let harness = givenUpHarness()
        defer { harness.tearDown() }
        harness.hal.startStatus = noErr
        _ = harness.state.requestQuit()
        let calls = harness.hal.calls.count

        harness.state.retryMicrophoneMeter()
        harness.settle()

        XCTAssertEqual(harness.state.microphoneError, startFailedMessage, "nothing changes after a Quit request")
        XCTAssertTrue(harness.state.microphoneMeterGaveUp)
        XCTAssertEqual(harness.lifecycleCalls(after: calls), [])
    }

    func testAnotherDefaultInputStartsOverWithoutRetryAndWithdrawsIt() {
        let harness = givenUpHarness()
        defer { harness.tearDown() }
        harness.hal.startStatus = noErr
        let usbMicrophone = AudioStateHarness.usbMicrophone

        harness.system.setDefault(usbMicrophone, for: .input)
        harness.poll()
        XCTAssertFalse(harness.state.microphoneMeterGaveUp, "Retry goes with the input it was for")
        XCTAssertNil(harness.state.microphoneError)

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.start(usbMicrophone)))
        XCTAssertEqual(starts(harness), maximum, "nothing more on the input it gave up on")
    }

    func testACoreAudioRestartStartsOverWithoutRetryAndWithdrawsIt() {
        let harness = givenUpHarness()
        defer { harness.tearDown() }
        harness.hal.startStatus = noErr

        harness.fireSystemNotification(.serviceRestarted)
        harness.settle()
        XCTAssertFalse(harness.state.microphoneMeterGaveUp)
        XCTAssertEqual(starts(harness), maximum, "nothing starts inside the window the restart armed")

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(starts(harness), maximum + 1)
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertNil(harness.state.microphoneError)
    }

    func testTheMetersRetryStartsTheMeterAloneAndLeavesAHaltedProcessedMicrophoneToItsOwnRetry() {
        let harness = givenUpHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        XCTAssertEqual(
            harness.state.processedMicrophoneState,
            .failed(startFailedMessage),
            "the publication that waited for the meter halts, failed with its own Retry"
        )
        XCTAssertEqual(harness.state.microphoneError, startFailedMessage)

        // The meter's Retry starts the meter alone.
        harness.hal.startStatus = noErr
        harness.state.retryMicrophoneMeter()
        harness.settle()
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertFalse(harness.state.microphoneMeterGaveUp)
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(startFailedMessage))

        harness.state.retryProcessedMicrophone()
        harness.settle()
        harness.poll()
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
    }

    func testTheProcessedMicrophonesRetryAloneStartsBothOverAndWithdrawsTheMetersRetry() {
        let harness = givenUpHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.hal.startStatus = noErr

        harness.state.retryProcessedMicrophone()
        harness.settle()
        harness.poll()

        XCTAssertFalse(harness.state.microphoneMeterGaveUp)
        XCTAssertNil(harness.state.microphoneError)
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
        XCTAssertEqual(starts(harness), maximum + 1, "one meter start, which the publication then waited for")
    }
}
