import AudioLevelBarCore
import Combine
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// How `AudioState`'s evaluation binds each step to what the quiet window
/// admits, through the harness: nothing reaches coreaudiod.
final class AudioStateEvaluationTests: XCTestCase {
    private let microphone = AudioStateHarness.builtInMicrophone
    private let usbMicrophone = AudioStateHarness.usbMicrophone

    func testTheLaunchWindowHoldsEveryStartUntilAPollIssuedAfterItsEndApplies() {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }

        harness.launch()
        harness.advance(by: 1)
        harness.poll()
        harness.advance(by: 2.1)
        // The window's settle period is over, but the newest poll was issued
        // inside it.
        harness.evaluate()
        harness.settle()

        XCTAssertEqual(harness.hal.lifecycleCalls, [], "nothing is created or started inside the launch window")
        XCTAssertEqual(harness.state.microphoneDisplay, .starting, "the display follows the target at once")
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .starting)

        harness.poll()

        let release = harness.timelineIndex(ofLineWithPrefix: "quiet-window release mode=full")
        let meterCreate = harness.timelineIndex(of: .createIOProc(microphone))
        let tapCreate = harness.timelineIndex(of: .createProcessTap)
        XCTAssertNotNil(release)
        XCTAssertNotNil(meterCreate)
        XCTAssertNotNil(tapCreate)
        if let release, let meterCreate, let tapCreate {
            XCTAssertLessThan(release, meterCreate, "the release is noted before the meter starts")
            XCTAssertLessThan(release, tapCreate, "and before the system playback meter is built")
        }
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)
    }

    func testAReleaseForcedByTheCapStopsTheMeterOnThePreviousInputAndStartsNothing() {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }
        harness.launchAndRelease()
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)

        harness.system.setDefault(usbMicrophone, for: .input)
        harness.moveDefaultOutput(to: AudioStateHarness.usbOutput)
        harness.poll()
        XCTAssertEqual(harness.holdReasons.last, "default-input,default-output")
        // A change every 2.5 s keeps the window holding until its cap.
        for _ in 0..<5 {
            harness.advance(by: 2.5)
            harness.fireSystemNotification(.defaultInput)
            harness.settle()
        }
        let beforeRelease = harness.hal.calls.count

        harness.advance(by: 2.5)
        harness.poll()

        XCTAssertEqual(harness.lines(withPrefix: "quiet-window release ").last.flatMap {
            AudioStateHarness.field("mode", of: $0)
        }, "stops-only")
        XCTAssertEqual(
            harness.lifecycleCalls(after: beforeRelease),
            [.stop(microphone), .destroyIOProc(microphone)],
            "the meter on the previous input stops; neither it nor the system playback meter starts again"
        )
        XCTAssertEqual(harness.holdReasons.last, "carried", "the rest of the last change's settle period holds")

        let beforeFullRelease = harness.hal.calls.count
        harness.advance(by: 0.6)
        harness.poll()

        let calls = harness.lifecycleCalls(after: beforeFullRelease)
        XCTAssertTrue(calls.contains(.createIOProc(usbMicrophone)), "\(calls)")
        XCTAssertTrue(calls.contains(.createProcessTap), "the owed rebuild runs at the full release: \(calls)")
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
    }

    // MARK: Pickers

    func testAPollReadBeforeAnInputPickNeitherBringsTheOldInputBackNorHoldsTheOutputBack() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launchAndRelease()
        var inputs: [AudioDeviceID] = []
        let subscription = harness.state.$inputDeviceID.sink { inputs.append($0) }
        defer { subscription.cancel() }

        harness.moveDefaultOutput(to: AudioStateHarness.usbOutput)
        // The poll reads the defaults on the HAL queue, the pick's write
        // queues behind it, and the poll's result reaches the main thread
        // after the pick.
        harness.scheduler.tick()
        harness.state.selectInputDevice(usbMicrophone)
        harness.settle()

        let sincePick = inputs.drop { $0 != usbMicrophone }
        XCTAssertFalse(sincePick.isEmpty)
        XCTAssertFalse(
            sincePick.contains(microphone),
            "a poll read before the pick does not bring the previous input back: \(inputs)"
        )
        XCTAssertEqual(
            harness.state.outputDeviceID,
            AudioStateHarness.usbOutput,
            "that poll still moves the output, for which no write is outstanding"
        )
    }

    func testARejectedPickerWriteEndsItsHoldSoALaterPickStartsTheMeter() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launchAndRelease()

        harness.system.writeStatus = kAudioHardwareUnspecifiedError
        harness.state.selectInputDevice(usbMicrophone)
        harness.settle()
        XCTAssertEqual(harness.state.inputDeviceID, microphone, "the rejected pick is rolled back")

        harness.system.writeStatus = noErr
        harness.state.selectInputDevice(usbMicrophone)
        harness.settle()
        let beforeRelease = harness.hal.calls.count
        // The first poll after the write sees the new default input and holds
        // the window again; the one after that releases it.
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()

        let calls = harness.lifecycleCalls(after: beforeRelease)
        XCTAssertTrue(
            calls.contains(.createIOProc(usbMicrophone)),
            "no write is left outstanding to hold the window: \(calls)"
        )
    }

    // MARK: Quit

    func testQuitStopsThePublisherWithdrawsThePublicationThenStopsTheMetersAndWaitsForThem() {
        let harness = AudioStateHarness(systemOutputMonitoring: true, processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)
        // The consuming app has let go, so Quit can withdraw the publication.
        harness.hal.isRunningSomewhereRead = (noErr, 0)
        // The withdrawal takes a while on the main thread. A stop handed to a
        // lifecycle queue before it would run meanwhile.
        let publishedAggregate = AudioStateHarness.publishedAggregate
        harness.holds.onEnter = { point in
            if point == .hal(.destroyAggregate(publishedAggregate)) {
                usleep(100_000)
            }
        }
        let before = harness.hal.timeline.count

        harness.state.stop()
        harness.settle()

        let timeline = Array(harness.hal.timeline.dropFirst(before))
        func line(_ prefix: String, containing text: String = "") -> Int? {
            timeline.firstIndex { entry in
                guard case let .line(line) = entry else {
                    return false
                }
                return line.hasPrefix(prefix) && (text.isEmpty || line.contains(text))
            }
        }
        guard
            let publisherStop = line("processed-microphone-publisher-engine stop ", containing: "reason=quit"),
            let aggregateWithdrawal = timeline.firstIndex(of: .call(.destroyAggregate(publishedAggregate))),
            let tapWithdrawal = timeline.firstIndex(of: .call(.destroyProcessTap(AudioStateHarness.publishedTap))),
            let systemOutputStop = timeline.firstIndex(of: .call(.stop(AudioStateHarness.systemOutputAggregate))),
            let systemOutputTapDestroy = timeline.firstIndex(
                of: .call(.destroyProcessTap(AudioStateHarness.systemOutputTap))
            ),
            let captureDestroy = timeline.firstIndex(of: .call(.destroyIOProc(microphone))),
            let wait = line("quit lifecycle-stops completed=true")
        else {
            return XCTFail("a Quit step is missing: \(timeline)")
        }
        XCTAssertLessThan(publisherStop, aggregateWithdrawal, "the publisher stops before its muted tap is withdrawn")
        XCTAssertLessThan(tapWithdrawal, systemOutputStop, "the meters' stops are handed over after the withdrawal")
        XCTAssertLessThan(systemOutputTapDestroy, wait, "Quit waits for the system playback meter's release")
        XCTAssertLessThan(captureDestroy, wait, "and for the capture's")
    }
}
