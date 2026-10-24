import AVFoundation
import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// How `AudioState` watches lifecycle calls that do not come back, arms the
/// quiet window from the meter's reports, and hands the input over, through
/// the harness: a held fake call stands in for a coreaudiod that does not
/// answer, and nothing reaches coreaudiod.
final class AudioStateWatchTests: XCTestCase {
    private let microphone = AudioStateHarness.builtInMicrophone
    private let usbMicrophone = AudioStateHarness.usbMicrophone

    // MARK: Microphone meter

    func testAStalledMeterStartShowsTheStallAndClearsItWhenTheStartReportsInterrupted() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launch()
        let target = microphone
        harness.holds.hold { point, _ in point == .hal(.createIOProc(target)) }
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(harness.holds.entered, [.hal(.createIOProc(microphone))])

        harness.advance(by: MeterSession.startTimeout)
        harness.evaluate()
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.microphoneStallMessage)
        XCTAssertEqual(harness.lines(withPrefix: "microphone-ioproc stall ").count, 1)

        // A window arms while the create is still in coreaudiod.
        harness.fireSystemNotification(.defaultInput)
        harness.drainMainQueue()
        harness.holds.releaseAll()
        harness.settle()

        XCTAssertEqual(harness.lines(withPrefix: "microphone-ioproc interrupt id=\(microphone) ").count, 1)
        XCTAssertNil(harness.state.microphoneError, "the start reported, so Core Audio has answered")
    }

    func testARefusedMeterStartHoldsTheWindowAndExhaustedRefusalsSayWhyAndHaltAWaitingPublication() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        // The meter's own read of the device's transport, immediately before
        // it opens it, fails every time.
        harness.hal.setTransportInfo(nil, for: microphone)
        harness.launch()

        for _ in 0..<MeterSession.maximumStartAttempts {
            harness.advance(by: MeterSession.maximumRetryDelay + LifecycleQuietWindow.settle)
            harness.poll()
        }

        XCTAssertEqual(
            harness.lines(withPrefix: "microphone-ioproc refuse id=\(microphone) ").count,
            MeterSession.maximumStartAttempts
        )
        XCTAssertEqual(
            harness.holdReasons.filter { $0 == "meter-refused" }.count,
            MeterSession.maximumStartAttempts,
            "each refusal holds the window, so the retry waits for a quiet period and a fresh poll"
        )
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.microphoneTransportUnreadMessage)
        XCTAssertEqual(
            harness.state.processedMicrophoneState,
            .failed(AudioStateHarness.microphoneTransportUnreadMessage),
            "a publication waiting for the meter does not wait for good"
        )
        XCTAssertEqual(harness.hal.lifecycleCalls, [], "nothing was opened")
    }

    func testAnInvalidationWhileTheMeterStartsHoldsTheWindowAtOnceAndAgainWhenTheStartReports() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launch()
        let target = microphone
        harness.holds.hold { point, _ in point == .hal(.start(target)) }
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(harness.holds.entered, [.hal(.start(microphone))])
        let reasonsBefore = harness.holdReasons.count

        harness.hal.fireListener(deviceID: microphone, selector: kAudioDevicePropertyDeviceIsAlive)
        harness.drainMainQueue()
        XCTAssertEqual(Array(harness.holdReasons.dropFirst(reasonsBefore)), ["meter-invalidated"])

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertEqual(
            Array(harness.holdReasons.dropFirst(reasonsBefore)),
            ["meter-invalidated", "meter-invalidated"],
            "the invalidation applies when the start reports, and holds a window from then"
        )
        XCTAssertEqual(harness.state.microphoneDisplay, .starting)
    }

    // MARK: System playback meter

    func testAStalledSystemPlaybackCallHoldsARetryBackUntilItsQueueAnswers() {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }
        harness.launch()
        harness.holds.hold { point, _ in point == .hal(.createProcessTap) }
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(harness.holds.entered, [.hal(.createProcessTap)])

        harness.advance(by: LifecycleCallWatch.timeout)
        harness.evaluate()
        XCTAssertEqual(
            harness.state.systemOutputMonitoringState,
            .failed(AudioStateHarness.systemOutputStallMessage)
        )
        XCTAssertEqual(harness.lines(withPrefix: "system-output-tap stall ").count, 1)

        harness.state.retrySystemOutputMonitoring()
        harness.advance(by: LifecycleCallWatch.timeout)
        harness.evaluate()
        XCTAssertEqual(
            harness.lines(withPrefix: "system-output-tap stall ").count,
            1,
            "the Retry issued nothing behind the call that has not come back, so nothing new stalls"
        )

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)
        XCTAssertEqual(
            harness.hal.lifecycleCalls.filter { $0 == .createProcessTap }.count,
            2,
            "the held build, then the Retry's rebuild once the queue answered"
        )
    }

    /// The system playback meter's aggregate device reports a stream
    /// configuration change, then the window and the longest spacing pass
    /// with two polls after them.
    private func invalidateSystemOutputMeterAndRelease(_ harness: AudioStateHarness) {
        harness.hal.fireListener(
            deviceID: AudioStateHarness.systemOutputAggregate,
            selector: kAudioDevicePropertyStreamConfiguration
        )
        harness.drainMainQueue()
        harness.settle()
        harness.advance(by: SystemOutputRecovery.maximumRetryDelay + LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.advance(by: 0.3)
        harness.poll()
    }

    /// The system playback meter's tap creates, by their own lines: the
    /// processed microphone's publication creates a process tap too.
    private func systemOutputBuilds(_ harness: AudioStateHarness) -> Int {
        harness.lines(withPrefix: "system-output-tap create ").count
    }

    /// The system playback meter's releases, by their own lines.
    private func systemOutputReleases(_ harness: AudioStateHarness) -> Int {
        harness.lines(withPrefix: "system-output-tap destroy ").count
            + harness.lines(withPrefix: "system-output-aggregate destroy ").count
    }

    /// Launches with monitoring on, and invalidates the meter until its
    /// rebuilds give up.
    private func exhaustedSystemOutputHarness(file: StaticString = #filePath, line: UInt = #line) -> AudioStateHarness {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        harness.launchAndRelease(file: file, line: line)
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active, file: file, line: line)
        for _ in 0..<SystemOutputRecovery.maximumConsecutiveInvalidations {
            invalidateSystemOutputMeterAndRelease(harness)
        }
        return harness
    }

    func testAnOutputThatKeepsInvalidatingTheMeterGivesUpAndIssuesNothingUntilRetry() {
        let harness = exhaustedSystemOutputHarness()
        defer { harness.tearDown() }
        let maximum = SystemOutputRecovery.maximumConsecutiveInvalidations

        XCTAssertEqual(
            systemOutputBuilds(harness),
            maximum,
            "the launch build and one rebuild for each invalidation before the last"
        )
        XCTAssertEqual(
            harness.state.systemOutputMonitoringState,
            .failed(AudioStateHarness.systemOutputRebuildsExhaustedMessage)
        )
        let giveUps = harness.lines(withPrefix: "system-output-tap give-up ")
        XCTAssertEqual(giveUps.count, 1)
        XCTAssertEqual(giveUps.first.flatMap { AudioStateHarness.field("output", of: $0) }, "\(AudioStateHarness.speakers)")

        let releasesAtGiveUp = systemOutputReleases(harness)
        for _ in 0..<3 {
            harness.advance(by: SystemOutputRecovery.maximumRetryDelay + LifecycleQuietWindow.settle + 0.1)
            harness.poll()
        }
        // Publication finishing, or the processed microphone switched off,
        // asks for a rebuild too.
        harness.state.setProcessedMicrophoneEnabled(true)
        harness.state.setProcessedMicrophoneEnabled(false)
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.poll()
        XCTAssertEqual(systemOutputBuilds(harness), maximum, "no rebuild")
        XCTAssertEqual(
            systemOutputReleases(harness),
            releasesAtGiveUp,
            "and no release of what the last build holds"
        )
        XCTAssertEqual(
            harness.state.systemOutputMonitoringState,
            .failed(AudioStateHarness.systemOutputRebuildsExhaustedMessage)
        )

        harness.state.retrySystemOutputMonitoring()
        harness.settle()
        // The processed microphone's teardown, once its window has passed,
        // asks for one more rebuild of its own.
        for _ in 0..<4 where harness.state.systemOutputMonitoringState != .active {
            harness.advance(by: LifecycleQuietWindow.settle + 0.1)
            harness.poll()
        }
        XCTAssertGreaterThan(systemOutputBuilds(harness), maximum, "the retry rebuilds")
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)

        let buildsAfterRetry = systemOutputBuilds(harness)
        invalidateSystemOutputMeterAndRelease(harness)
        XCTAssertEqual(systemOutputBuilds(harness), buildsAfterRetry + 1, "and the next invalidation is rebuilt again")
        XCTAssertEqual(harness.lines(withPrefix: "system-output-tap give-up ").count, 1)
    }

    func testRebuildsThatGaveUpStartOverWhenTheOutputChanges() {
        let harness = exhaustedSystemOutputHarness()
        defer { harness.tearDown() }
        let maximum = SystemOutputRecovery.maximumConsecutiveInvalidations
        XCTAssertEqual(systemOutputBuilds(harness), maximum)

        harness.moveDefaultOutput(to: AudioStateHarness.usbOutput)
        harness.poll()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.poll()

        XCTAssertEqual(systemOutputBuilds(harness), maximum + 1, "the new output is metered")
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)
    }

    func testRebuildsThatGaveUpStayGivenUpAcrossACoreAudioRestart() {
        let harness = exhaustedSystemOutputHarness()
        defer { harness.tearDown() }
        let maximum = SystemOutputRecovery.maximumConsecutiveInvalidations

        harness.fireSystemNotification(.serviceRestarted)
        harness.drainMainQueue()
        harness.settle()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        harness.poll()

        XCTAssertEqual(systemOutputBuilds(harness), maximum)
        XCTAssertEqual(
            harness.state.systemOutputMonitoringState,
            .failed(AudioStateHarness.systemOutputRebuildsExhaustedMessage)
        )
    }

    // MARK: Processed microphone

    func testAHandOffWaitsForAMeterStartThatHasNotReportedBack() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.system.setDefault(usbMicrophone, for: .input)
        harness.poll()
        let target = usbMicrophone
        harness.holds.hold { point, _ in point == .hal(.start(target)) }
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertEqual(harness.holds.entered, [.hal(.start(usbMicrophone))])

        harness.setPublishedDeviceInUse(true)
        harness.drainMainQueue()
        XCTAssertEqual(
            harness.state.microphoneDisplay,
            .starting,
            "the input is not handed over while the meter's start has not reported back"
        )

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertEqual(harness.state.microphoneDisplay, .notMeasured(.handedOff))
        XCTAssertEqual(
            harness.state.processedMicrophoneState,
            .active,
            "the evaluation after the start reported hands the input over"
        )
    }

    func testAStalledCaptureStartShowsTheStallAndClearsItWhenTheStartReports() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.holdCaptureStart()
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.holds.entered, [.hal(.start(microphone))])

        harness.advance(by: LifecycleCallWatch.timeout)
        harness.poll()
        XCTAssertEqual(harness.lines(withPrefix: "processed-microphone-capture-ioproc stall ").count, 1)
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.processedMicrophoneStallMessage)

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .active)
        XCTAssertNil(harness.state.microphoneError)
    }

    func testNeitherThePlanNorARetryTearsThePublicationDownBehindAStalledCapture() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.holdCaptureStart()
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        harness.advance(by: LifecycleCallWatch.timeout)
        harness.poll()
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.processedMicrophoneStallMessage)
        let published = AudioStateHarness.publishedAggregate

        harness.setPublishedDeviceInUse(false)
        harness.state.setProcessedMicrophoneEnabled(false)
        harness.settle()
        XCTAssertFalse(
            harness.hal.lifecycleCalls.contains(.destroyAggregate(published)),
            "the owed teardown waits for the capture queue"
        )

        harness.state.retryProcessedMicrophone()
        harness.settle()
        XCTAssertFalse(
            harness.hal.lifecycleCalls.contains(.destroyAggregate(published)),
            "and so does a Retry"
        )

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertTrue(
            harness.hal.lifecycleCalls.contains(.destroyAggregate(published)),
            "the teardown runs once the queue answers"
        )
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)
    }

    func testAServiceRestartWatchesTheCaptureQueueForTheStartItSuperseded() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.holdCaptureStart()
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.holds.entered, [.hal(.start(microphone))])

        harness.fireSystemNotification(.serviceRestarted)
        harness.settle()
        harness.holds.releaseAll()
        harness.settle()

        harness.advance(by: LifecycleCallWatch.timeout + 1)
        harness.poll()
        XCTAssertTrue(
            harness.lines(withPrefix: "processed-microphone-capture-ioproc stall ").isEmpty,
            "the capture queue answered; the start the restart superseded never reports, and is not taken for a stall"
        )
        XCTAssertNotEqual(harness.state.microphoneError, AudioStateHarness.processedMicrophoneStallMessage)
    }

    func testAServiceRestartStillShowsAStallWhileTheCaptureQueueStaysBlocked() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.holdCaptureStart()
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.holds.entered, [.hal(.start(microphone))])

        // The capture queue is still blocked in the old server when the
        // restart arrives, and stays blocked.
        harness.fireSystemNotification(.serviceRestarted)
        harness.drainMainQueue()
        harness.settle()
        let entered = harness.holds.entered.count
        let calls = harness.hal.calls.count

        harness.advance(by: LifecycleCallWatch.timeout + 0.1)
        harness.poll()
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-capture-ioproc stall ").count,
            1,
            "the watch the restart issued stalls, since the queue never answers"
        )
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.processedMicrophoneStallMessage)
        XCTAssertFalse(
            harness.lifecycleCalls(after: calls).contains(.destroyAggregate(AudioStateHarness.publishedAggregate)),
            "nothing is torn down behind the stall"
        )
        XCTAssertEqual(harness.holds.entered.count, entered, "and nothing is issued behind it")

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertNotEqual(harness.state.microphoneError, AudioStateHarness.processedMicrophoneStallMessage)
    }

    func testAStalledHandOffStopShowsTheStallAndClearsItWhenTheStopReports() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        let meterQueue = harness.state.lifecycleQueuesForTesting.microphoneMeter.label
        let target = microphone
        harness.holds.hold { point, queueLabel in
            point == .hal(.stop(target)) && queueLabel == meterQueue
        }
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.holds.entered, [.hal(.stop(microphone))])

        harness.advance(by: LifecycleCallWatch.timeout)
        harness.poll()
        let stalls = harness.lines(withPrefix: "microphone-ioproc stall id=\(microphone) ")
        XCTAssertEqual(stalls.count, 1)
        XCTAssertEqual(stalls.first.flatMap { AudioStateHarness.field("reason", of: $0) }, "hand-off")
        XCTAssertEqual(harness.state.microphoneError, AudioStateHarness.processedMicrophoneStallMessage)

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertNil(harness.state.microphoneError, "the hand-off stop came back")
        XCTAssertEqual(harness.state.processedMicrophoneState, .active, "and the hand-off went ahead")
    }

    func testARestartRequestWhileTheCaptureStartsDoesNotEndTheWatchOnThatStart() {
        let harness = AudioStateHarness(processedMicrophone: true)
        defer { harness.tearDown() }
        harness.launchAndPublish()
        harness.holdCaptureStart()
        harness.setPublishedDeviceInUse(true)
        harness.settle()
        XCTAssertEqual(harness.holds.entered, [.hal(.start(microphone))])

        // The publisher's output reconfigures while the capture's
        // AudioDeviceStart is still in coreaudiod.
        harness.hal.fireListener(deviceID: AudioStateHarness.speakers, selector: kAudioDevicePropertyNominalSampleRate)
        harness.settle()
        XCTAssertEqual(harness.holdReasons.last, "processing-invalidated")

        harness.advance(by: LifecycleCallWatch.timeout)
        harness.poll()
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-capture-ioproc stall ").count,
            1,
            "the start has not come back, whatever the engine asked for meanwhile"
        )

        harness.holds.releaseAll()
        harness.settle()
        XCTAssertNotEqual(harness.state.microphoneError, AudioStateHarness.processedMicrophoneStallMessage)
    }
}
