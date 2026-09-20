import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// What `AudioState` does when a listener advances the quiet window's
/// generation while the processed microphone's publication is making its
/// calls on the main thread, through the harness: nothing reaches coreaudiod.
///
/// The publication stops before its next HAL call and rolls nothing back
/// inside the window, what it created is never reported as published, and
/// the first evaluation after the window rolls it back and, once starts are
/// admitted and it is still wanted and allowed, publishes again.
final class AudioStatePublicationInterruptTests: XCTestCase {
    private let microphone = AudioStateHarness.builtInMicrophone
    private let aggregate = AudioStateHarness.publishedAggregate
    private let tap = AudioStateHarness.publishedTap

    private var publication: [FakeHALLifecycleCalls.Call] {
        [
            .createProcessTap, .createAggregate,
            .createIOProc(aggregate), .start(aggregate), .stop(aggregate), .destroyIOProc(aggregate)
        ]
    }

    /// Launches with the processed microphone on and lets the launch window
    /// end. A default-input listener fires inside the publication's first
    /// call equal to `call`, on the main thread where the publication runs,
    /// as the listener queue would while that call waits in coreaudiod;
    /// `change` runs first, to move what the next poll reads.
    private func launch(
        interruptingIn call: FakeHALLifecycleCalls.Call,
        change: ((AudioStateHarness) -> Void)? = nil
    ) -> AudioStateHarness {
        let harness = AudioStateHarness(processedMicrophone: true)
        harness.launch()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        var fired = false
        harness.holds.onEnter = { [unowned harness] point in
            // The publication's calls are all made on the main thread.
            guard point == .hal(call), !fired else {
                return
            }
            fired = true
            change?(harness)
            harness.fireSystemNotification(.defaultInput)
        }
        harness.poll()
        return harness
    }

    private func generation(of line: String?) -> String? {
        line.flatMap { AudioStateHarness.field("gen", of: $0) }
    }

    func testADeviceChangeDuringThePublicationStopsItBeforeItsNextCallAndTheReleaseRollsItBackAndPublishesAgain() {
        let harness = launch(interruptingIn: .createAggregate)
        defer { harness.tearDown() }

        XCTAssertEqual(
            harness.hal.lifecycleCalls,
            [.createIOProc(microphone), .start(microphone), .createProcessTap, .createAggregate],
            "no probe IOProc is created or started once the generation has advanced, and nothing is rolled back"
        )
        let issuedIn = generation(of: harness.lines(withPrefix: "quiet-window release ").last)
        XCTAssertNotNil(issuedIn)
        let interrupts = harness.lines.values.filter {
            $0.hasPrefix("processed-microphone-") && $0.contains(" interrupt ")
        }
        XCTAssertEqual(interrupts.count, 1, "\(interrupts)")
        XCTAssertEqual(
            interrupts.first?.hasPrefix("processed-microphone-probe-ioproc interrupt id=\(aggregate) "),
            true,
            "the line names the object whose call was held back: \(interrupts)"
        )
        XCTAssertEqual(generation(of: interrupts.first), issuedIn, "and the generation the publication was issued in")
        XCTAssertEqual(interrupts.first.flatMap { AudioStateHarness.field("reason", of: $0) }, "before-create")
        let begins = harness.lines.values.filter { $0.hasPrefix("processed-microphone-") && $0.contains("-begin ") }
        XCTAssertEqual(begins.count, 2, "\(begins)")
        for line in begins {
            XCTAssertEqual(generation(of: line), issuedIn, "every begin line carries that generation: \(line)")
        }
        XCTAssertEqual(harness.holdReasons.last, "hal-notification")
        XCTAssertEqual(
            harness.state.processedMicrophoneState,
            .starting,
            "a tap and an aggregate device whose probe has not passed are not reported as published"
        )

        // Nothing is issued for it while the window holds.
        let kept = harness.hal.calls.count
        harness.advance(by: 1)
        harness.poll()
        XCTAssertEqual(harness.lifecycleCalls(after: kept), [])

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()

        XCTAssertEqual(
            harness.lifecycleCalls(after: kept),
            [.destroyAggregate(aggregate), .destroyProcessTap(tap)] + publication,
            "the release rolls back what was kept, the tap after its aggregate device, and publishes afresh"
        )
        let rolledBackIn = generation(of: harness.lines(withPrefix: "quiet-window release ").last)
        XCTAssertNotEqual(rolledBackIn, issuedIn)
        XCTAssertEqual(
            generation(of: harness.lines(withPrefix: "processed-microphone-aggregate destroy-begin ").last),
            rolledBackIn,
            "the rollback carries the generation of the release that issued it"
        )
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
    }

    func testAProbeTheWindowFindsRunningKeepsRunningUntilTheReleaseStopsItFirst() {
        let harness = launch(interruptingIn: .start(aggregate))
        defer { harness.tearDown() }

        XCTAssertEqual(
            harness.hal.lifecycleCalls,
            [
                .createIOProc(microphone), .start(microphone),
                .createProcessTap, .createAggregate, .createIOProc(aggregate), .start(aggregate)
            ],
            "the probe is neither stopped nor destroyed inside the window"
        )
        XCTAssertEqual(
            harness.lines(withPrefix: "processed-microphone-probe-ioproc interrupt ")
                .first
                .flatMap { AudioStateHarness.field("reason", of: $0) },
            "before-stop"
        )
        XCTAssertEqual(harness.state.processedMicrophoneState, .starting)
        let kept = harness.hal.calls.count

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()

        XCTAssertEqual(
            Array(harness.hal.calls.dropFirst(kept).prefix(5)),
            [
                .stop(aggregate), .destroyIOProc(aggregate),
                .readIsRunningSomewhere(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)
            ],
            "the probe goes first, and in use is read immediately before the aggregate device's destroy"
        )
        XCTAssertEqual(Array(harness.lifecycleCalls(after: kept).dropFirst(4)), publication)
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
    }

    func testWhatAnInterruptedPublicationKeptDoesNotOutliveTheWindowWhenTheSourceIsRefusedByThen() {
        // The change that interrupted the publication made a Bluetooth
        // headset the default input.
        let harness = launch(interruptingIn: .start(aggregate)) { harness in
            harness.connectHeadset()
            harness.system.setDefault(AudioStateHarness.headset, for: .input)
        }
        defer { harness.tearDown() }
        let kept = harness.hal.calls.count

        harness.advance(by: 1)
        harness.poll()
        guard case .refused(_, published: false) = harness.state.processedMicrophoneState else {
            return XCTFail("\(harness.state.processedMicrophoneState)")
        }
        XCTAssertEqual(harness.lifecycleCalls(after: kept), [], "nothing inside the window")

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()

        let released = harness.lifecycleCalls(after: kept)
        XCTAssertEqual(
            Array(released.prefix(4)),
            [.stop(aggregate), .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)],
            "the release rolls it back although nothing is published again"
        )
        XCTAssertFalse(released.contains(.createProcessTap), "\(released)")
        XCTAssertFalse(released.contains(.createIOProc(AudioStateHarness.headset)), "\(released)")
        guard case .refused(_, published: false) = harness.state.processedMicrophoneState else {
            return XCTFail("\(harness.state.processedMicrophoneState)")
        }
    }

    func testSwitchingOffInsideTheWindowRollsBackAtTheReleaseAndPublishesNothing() {
        let harness = launch(interruptingIn: .createIOProc(aggregate))
        defer { harness.tearDown() }
        let kept = harness.hal.calls.count

        harness.state.setProcessedMicrophoneEnabled(false)
        harness.settle()
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)
        XCTAssertEqual(harness.lifecycleCalls(after: kept), [], "nothing inside the window")

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
        for _ in 0..<8 {
            harness.advance(by: 0.25)
            harness.poll()
        }

        XCTAssertEqual(
            harness.lifecycleCalls(after: kept),
            [.destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)]
        )
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)
    }

    func testAReleaseThatAdmitsStopsOnlyRollsBackAndTheNextFullReleasePublishes() {
        let harness = launch(interruptingIn: .start(aggregate))
        defer { harness.tearDown() }
        let kept = harness.hal.calls.count
        // A change every 2.5 s keeps the window holding until its cap.
        for _ in 0..<5 {
            harness.advance(by: 2.5)
            harness.fireSystemNotification(.defaultInput)
            harness.settle()
        }
        XCTAssertEqual(harness.lifecycleCalls(after: kept), [])

        harness.advance(by: 2.5)
        harness.poll()

        XCTAssertEqual(
            harness.lines(withPrefix: "quiet-window release ").last.flatMap { AudioStateHarness.field("mode", of: $0) },
            "stops-only"
        )
        XCTAssertEqual(
            harness.lifecycleCalls(after: kept),
            [.stop(aggregate), .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)],
            "a rollback only stops and destroys, so the probe does not run on until starts are admitted"
        )

        harness.advance(by: 0.6)
        harness.poll()

        XCTAssertEqual(Array(harness.lifecycleCalls(after: kept).dropFirst(4)), publication)
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
    }

    func testAHalfMadeDeviceAnAppOpenedInsideTheWindowIsNotDestroyedUntilTheAppLetsGo() {
        let harness = launch(interruptingIn: .createAggregate)
        defer { harness.tearDown() }
        let kept = harness.hal.calls.count
        harness.hal.isRunningSomewhereRead = (noErr, 1)

        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()

        XCTAssertEqual(harness.lifecycleCalls(after: kept), [], "nothing is destroyed under a consumer")
        XCTAssertTrue(harness.hal.calls.dropFirst(kept).contains(.readIsRunningSomewhere(aggregate)))
        guard case .failed = harness.state.processedMicrophoneState else {
            return XCTFail("the teardown is owed and the panel says why: \(harness.state.processedMicrophoneState)")
        }

        // The app lets go; the slow safety net reads it, since no in-use
        // listener watches a device that was never published.
        harness.hal.isRunningSomewhereRead = (noErr, 0)
        for _ in 0..<8 {
            harness.advance(by: 0.25)
            harness.poll()
        }

        XCTAssertEqual(
            harness.lifecycleCalls(after: kept),
            [.destroyAggregate(aggregate), .destroyProcessTap(tap)],
            "the owed teardown completes, and nothing is published again without a retry"
        )
    }

    // MARK: Publications interrupted in a row

    private let maximum = PublicationInterruptions.maximumConsecutiveInterruptions

    private var interruptedMessage: String {
        localized("The processed microphone stopped trying to start because audio device changes kept interrupting its setup. Choose Retry to try again.")
    }

    /// Whether a default-input listener fires inside every aggregate device
    /// create of a publication, as a HAL that posted a default-device
    /// notification around the app's own creates would make it.
    private final class Interrupting {
        var everyPublication = true
    }

    /// Launches with the processed microphone on and lets the launch window
    /// end, with every publication interrupted inside its aggregate device's
    /// create until the returned switch is turned off.
    private func launchInterruptingEveryPublication() -> (AudioStateHarness, Interrupting) {
        let harness = AudioStateHarness(processedMicrophone: true)
        let interrupting = Interrupting()
        harness.launch()
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.holds.onEnter = { [unowned harness] point in
            guard point == .hal(.createAggregate), interrupting.everyPublication else {
                return
            }
            harness.fireSystemNotification(.defaultInput)
        }
        harness.poll()
        return (harness, interrupting)
    }

    private func passWindow(_ harness: AudioStateHarness) {
        harness.advance(by: LifecycleQuietWindow.settle + 0.1)
        harness.poll()
    }

    private func publications(_ harness: AudioStateHarness) -> Int {
        harness.hal.lifecycleCalls.filter { $0 == .createProcessTap }.count
    }

    private func giveUps(_ harness: AudioStateHarness) -> [String] {
        harness.lines(withPrefix: "processed-microphone-aggregate give-up ")
    }

    func testTheLastPublicationInterruptedInARowIsRolledBackAndNothingIsPublishedAgainUntilRetry() {
        let (harness, interrupting) = launchInterruptingEveryPublication()
        defer { harness.tearDown() }

        XCTAssertEqual(publications(harness), 1)
        for count in 2...maximum {
            passWindow(harness)
            XCTAssertEqual(publications(harness), count, "each release rolls back and publishes again")
            XCTAssertEqual(harness.state.processedMicrophoneState, .starting)
        }
        XCTAssertEqual(giveUps(harness), [], "nothing is decided inside the window of the last interruption")
        let kept = harness.hal.calls.count

        passWindow(harness)

        XCTAssertEqual(
            harness.lifecycleCalls(after: kept),
            [.destroyAggregate(aggregate), .destroyProcessTap(tap)],
            "what the last publication kept is rolled back, and nothing is published again"
        )
        XCTAssertEqual(giveUps(harness).count, 1, "\(giveUps(harness))")
        let giveUp = giveUps(harness).first
        XCTAssertEqual(giveUp.flatMap { AudioStateHarness.field("id", of: $0) }, "0")
        XCTAssertEqual(
            giveUp.flatMap { AudioStateHarness.field("aggregate-uid", of: $0) },
            PublicProcessedMicrophoneDevice.aggregateDeviceUID
        )
        XCTAssertEqual(
            generation(of: giveUp),
            generation(of: harness.lines(withPrefix: "quiet-window release ").last),
            "the generation current when it is written, that of the release"
        )
        let rolledBack = harness.hal.timeline.lastIndex(of: .call(.destroyProcessTap(tap)))
        let gaveUp = harness.timelineIndex(ofLineWithPrefix: "processed-microphone-aggregate give-up ")
        XCTAssertNotNil(rolledBack)
        XCTAssertNotNil(gaveUp)
        if let rolledBack, let gaveUp {
            XCTAssertLessThan(rolledBack, gaveUp, "the give-up follows the rollback")
        }
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(interruptedMessage), "failed, which offers Retry")

        // Later releases publish nothing, whatever arms them.
        let halted = harness.hal.calls.count
        for _ in 0..<3 {
            harness.fireSystemNotification(.defaultInput)
            harness.settle()
            passWindow(harness)
        }
        XCTAssertEqual(harness.lifecycleCalls(after: halted), [])
        XCTAssertEqual(giveUps(harness).count, 1, "written once")
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(interruptedMessage))

        // Retry publishes again, and counts from zero.
        interrupting.everyPublication = false
        harness.state.retryProcessedMicrophone()
        harness.settle()

        XCTAssertEqual(harness.lifecycleCalls(after: halted), publication)
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
    }

    func testARetryAfterGivingUpCountsTheInterruptionsFromZeroAgain() {
        let (harness, _) = launchInterruptingEveryPublication()
        defer { harness.tearDown() }
        for _ in 0..<maximum {
            passWindow(harness)
        }
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(interruptedMessage))
        XCTAssertEqual(publications(harness), maximum)

        harness.state.retryProcessedMicrophone()
        harness.settle()
        XCTAssertEqual(publications(harness), maximum + 1, "the retry publishes at once")
        XCTAssertEqual(harness.state.processedMicrophoneState, .starting)

        for count in 2...maximum {
            passWindow(harness)
            XCTAssertEqual(publications(harness), maximum + count, "as many again before it gives up")
        }
        passWindow(harness)
        XCTAssertEqual(publications(harness), 2 * maximum)
        XCTAssertEqual(giveUps(harness).count, 2)
        XCTAssertEqual(harness.state.processedMicrophoneState, .failed(interruptedMessage))
    }

    func testAPublicationThatCompletesStartsTheCountOfInterruptionsOver() {
        let (harness, interrupting) = launchInterruptingEveryPublication()
        defer { harness.tearDown() }
        for _ in 2..<maximum {
            passWindow(harness)
        }
        XCTAssertEqual(publications(harness), maximum - 1, "one interruption short of giving up")

        // The next one completes.
        interrupting.everyPublication = false
        passWindow(harness)
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
        XCTAssertEqual(publications(harness), maximum)

        // coreaudiod restarts and takes the publication with it, and the
        // publications after it are interrupted again.
        interrupting.everyPublication = true
        harness.hal.listedDevices = []
        harness.fireSystemNotification(.serviceRestarted)
        harness.settle()
        for _ in 1..<maximum {
            passWindow(harness)
        }
        XCTAssertEqual(
            publications(harness),
            2 * maximum - 1,
            "the interruptions before the completed publication no longer count"
        )
        XCTAssertEqual(giveUps(harness), [])

        interrupting.everyPublication = false
        passWindow(harness)
        XCTAssertEqual(giveUps(harness), [])
        XCTAssertEqual(harness.state.processedMicrophoneState, .publishedIdle)
    }

    func testSwitchingOffStartsTheCountOfInterruptionsOver() {
        let (harness, _) = launchInterruptingEveryPublication()
        defer { harness.tearDown() }
        for _ in 2..<maximum {
            passWindow(harness)
        }
        XCTAssertEqual(publications(harness), maximum - 1)

        harness.state.setProcessedMicrophoneEnabled(false)
        harness.settle()
        passWindow(harness)
        XCTAssertEqual(harness.state.processedMicrophoneState, .disabled)
        harness.state.setProcessedMicrophoneEnabled(true)
        harness.settle()

        XCTAssertEqual(publications(harness), maximum, "switched on again, it publishes like a first time")
        for count in 1..<maximum {
            passWindow(harness)
            XCTAssertEqual(publications(harness), maximum + count)
            XCTAssertEqual(giveUps(harness), [])
        }
        passWindow(harness)
        XCTAssertEqual(giveUps(harness).count, 1, "and gives up only after as many interruptions in a row again")
    }
}
