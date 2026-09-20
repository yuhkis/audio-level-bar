import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// How `AudioState` recovers from a coreaudiod restart, holds for a
/// generation a listener advanced off the main thread, and re-arms after the
/// launch cleanup, through the harness: nothing reaches coreaudiod.
final class AudioStateRecoveryTests: XCTestCase {
    private let microphone = AudioStateHarness.builtInMicrophone
    private let usbMicrophone = AudioStateHarness.usbMicrophone

    func testAServiceRestartForgetsWithoutAHALCallAndRebuildsFromNothingAfterTheWindow() {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }
        harness.launchAndRelease()
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)
        let before = harness.hal.calls.count
        let linesBefore = harness.lines.values.count

        harness.fireSystemNotification(.serviceRestarted)
        harness.settle()

        XCTAssertEqual(
            Array(harness.hal.calls.dropFirst(before)),
            [],
            "nothing is stopped, destroyed or unlistened under IDs the new server may have reissued"
        )
        XCTAssertEqual(harness.holdReasons.last, "service-restarted")
        XCTAssertEqual(harness.system.forgottenLayoutCaches, 1, "the poll's caches keyed by device ID are dropped")
        let restartLines = harness.lines.values.dropFirst(linesBefore)
        XCTAssertEqual(restartLines.filter { $0.hasPrefix("microphone-ioproc forget id=\(microphone) ") }.count, 1)
        XCTAssertEqual(restartLines.filter { $0.hasPrefix("system-output-aggregate forget ") }.count, 1)
        XCTAssertEqual(harness.state.microphoneDisplay, .starting)
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .starting)

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()

        let rebuilt = harness.lifecycleCalls(after: before)
        XCTAssertTrue(rebuilt.contains(.createIOProc(microphone)), "the meter starts again: \(rebuilt)")
        XCTAssertTrue(rebuilt.contains(.createProcessTap), "the system playback meter is rebuilt: \(rebuilt)")
        let releases: [FakeHALLifecycleCalls.Call] = [
            .stop(microphone),
            .destroyIOProc(microphone),
            .stop(AudioStateHarness.systemOutputAggregate),
            .destroyIOProc(AudioStateHarness.systemOutputAggregate),
            .destroyAggregate(AudioStateHarness.systemOutputAggregate),
            .destroyProcessTap(AudioStateHarness.systemOutputTap)
        ]
        XCTAssertFalse(rebuilt.contains { releases.contains($0) }, "nothing forgotten is released first: \(rebuilt)")
        XCTAssertEqual(harness.state.microphoneDisplay, .live)
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)
    }

    func testAnEvaluationThatReadsAGenerationTheMainThreadHasNotArmedForHoldsAndArms() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launchAndRelease()
        harness.system.setDefault(usbMicrophone, for: .input)
        harness.poll()
        let before = harness.hal.calls.count
        let linesBefore = harness.lines.values.count
        let reasonsBefore = harness.holdReasons.count

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        // A poll issued after the window's end has read the defaults, and a
        // default-device listener advances the generation before the main
        // thread applies that poll.
        harness.scheduler.tick()
        harness.runLifecycleQueues()
        harness.fireSystemNotification(.defaultInput)
        harness.settle()

        XCTAssertEqual(Array(harness.holdReasons.dropFirst(reasonsBefore)), ["generation-advanced", "hal-notification"])
        XCTAssertFalse(
            harness.lifecycleCalls(after: before).contains(.createIOProc(usbMicrophone)),
            "nothing starts under a generation the main thread has not armed the window for"
        )
        XCTAssertFalse(
            harness.lines.values.dropFirst(linesBefore).contains { $0.hasPrefix("microphone-ioproc interrupt") },
            "no start is issued to be interrupted either"
        )

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        XCTAssertTrue(harness.lifecycleCalls(after: before).contains(.createIOProc(usbMicrophone)))
    }

    func testASystemPlaybackRebuildCarriesTheGenerationTheMainThreadSaw() {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }
        harness.launch()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        // A default-output listener advances the generation while the
        // release's rebuild reads the output's UID on the main thread.
        harness.system.onMainThreadUIDRead = { [unowned harness] deviceID in
            guard deviceID == AudioStateHarness.speakers else {
                return
            }
            harness.system.onMainThreadUIDRead = nil
            harness.fireSystemNotification(.defaultOutput)
        }

        harness.poll()

        XCTAssertFalse(harness.hal.lifecycleCalls.contains(.createProcessTap), "the rebuild stops before its first create")
        XCTAssertEqual(harness.lines(withPrefix: "system-output-tap interrupt ").count, 1)
        XCTAssertEqual(harness.holdReasons.last, "hal-notification")
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .starting)
    }

    func testALaunchCleanupThatDestroysAnEarlierRunsDeviceIssuesNothingMoreAndHoldsTheWindowAgain() {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }
        let earlierDevice: AudioObjectID = 900
        harness.hal.listedDevices = [(earlierDevice, PublicProcessedMicrophoneDevice.aggregateDeviceUID)]
        harness.launch()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)

        harness.poll()

        XCTAssertEqual(
            harness.hal.lifecycleCalls,
            [.destroyAggregate(earlierDevice)],
            "the earlier run's device goes, and nothing starts in the same evaluation"
        )
        XCTAssertEqual(harness.holdReasons.last, "launch-cleanup")
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-aggregate destroy id=\(earlierDevice) ")
                .first
                .flatMap { AudioStateHarness.field("reason", of: $0) },
            "launch"
        )

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()

        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.createIOProc(microphone)))
        XCTAssertTrue(harness.hal.lifecycleCalls.contains(.createProcessTap))
    }
}
