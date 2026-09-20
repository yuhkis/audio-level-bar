import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// Quit's order through the harness: the menu bar item goes at once, the
/// teardown waits for a quiet window that holds, at most
/// `QuitPlan.deferralMaximum` from the request, and nothing else reaches the
/// HAL meanwhile. Nothing here reaches coreaudiod.
final class QuitCoordinatorTests: XCTestCase {
    private static let statusItemRemoved = "test status-item removed"
    private static let terminationProceeds = "test termination proceeds"

    func testQuitInsideAWindowRemovesTheStatusItemAtOnceAndTearsDownThreeSecondsAfterTheLastChange() throws {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }
        harness.launchAndRelease()
        XCTAssertEqual(harness.state.systemOutputMonitoringState, .active)
        harness.moveDefaultOutput(to: AudioStateHarness.usbOutput)
        harness.poll()
        XCTAssertEqual(harness.holdReasons.last, "default-output")
        harness.advance(by: 1)
        let quit = coordinator(for: harness)
        let calls = harness.hal.calls.count
        let before = harness.hal.timeline.count

        XCTAssertEqual(quit.applicationShouldTerminate(), .later)

        XCTAssertEqual(
            Array(lines(harness, after: before).prefix(2)),
            ["quit-deferred release-in=2.00 gen=-", Self.statusItemRemoved],
            "the deferral is logged and the menu bar item goes at once"
        )
        XCTAssertFalse(harness.scheduler.isPolling, "polling stops at the request")

        // Meanwhile nothing the user does reaches the HAL.
        harness.state.setSystemOutputMonitoringEnabled(false)
        harness.state.selectInputDevice(AudioStateHarness.usbMicrophone)
        harness.advance(by: 0.5)
        harness.scheduler.tick()
        harness.settle()

        // 1.5 s into the deferral the default output's listener fires again,
        // as a headset switching profile does: the window's end moves to 3 s
        // after it, beyond the deadline.
        harness.advance(by: 1)
        harness.fireSystemNotification(.defaultOutput)
        harness.settle()
        harness.advance(by: 0.6)
        harness.settle()
        XCTAssertEqual(
            lines(harness, after: before).filter { $0.hasPrefix("quit-deferred ") },
            ["quit-deferred release-in=2.00 gen=-", "quit-deferred release-in=0.90 gen=-"],
            "the deferral came due, found the later change, and waits again up to the deadline"
        )

        // Another change before the deadline moves nothing past it.
        harness.advance(by: 0.4)
        harness.fireSystemNotification(.defaultInput)
        harness.settle()
        harness.advance(by: 0.4)
        harness.settle()
        XCTAssertEqual(harness.lifecycleCalls(after: calls), [], "nothing is issued during the deferral")
        XCTAssertTrue(harness.state.systemOutputMonitoringEnabled, "a toggle after Quit changes nothing")
        XCTAssertEqual(harness.state.inputDeviceID, AudioStateHarness.builtInMicrophone)
        XCTAssertFalse(lines(harness, after: before).contains { $0.contains("reason=quit") })
        XCTAssertFalse(lines(harness, after: before).contains(Self.terminationProceeds))

        // The deadline, 3 s after the request.
        harness.advance(by: 0.2)
        harness.settle()

        let timeline = lines(harness, after: before)
        XCTAssertEqual(timeline.filter { $0.hasPrefix("quit-deferred ") }.count, 2, "none after the deadline")
        let deferred = try XCTUnwrap(timeline.firstIndex { $0.hasPrefix("quit-deferred ") })
        let removed = try XCTUnwrap(timeline.firstIndex(of: Self.statusItemRemoved))
        let firstQuitStop = try XCTUnwrap(timeline.firstIndex { $0.contains("reason=quit") })
        let wait = try XCTUnwrap(timeline.firstIndex { $0.hasPrefix("quit lifecycle-stops completed=true") })
        let proceeds = try XCTUnwrap(timeline.firstIndex(of: Self.terminationProceeds))
        XCTAssertLessThan(deferred, removed)
        XCTAssertLessThan(removed, firstQuitStop, "the teardown follows the status item's removal")
        XCTAssertLessThan(firstQuitStop, wait)
        XCTAssertLessThan(wait, proceeds, "termination proceeds once the teardown has waited")
        XCTAssertTrue(
            harness.lifecycleCalls(after: calls).contains(.destroyProcessTap(AudioStateHarness.systemOutputTap)),
            "the system playback tap is destroyed by the teardown"
        )
    }

    func testQuitOutsideAWindowTearsDownAtOnceAfterRemovingTheStatusItem() throws {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }
        harness.launchAndRelease()
        let quit = coordinator(for: harness)
        let before = harness.hal.timeline.count

        XCTAssertEqual(quit.applicationShouldTerminate(), .now)

        let timeline = lines(harness, after: before)
        XCTAssertFalse(timeline.contains { $0.hasPrefix("quit-deferred ") }, "no deferral outside a window")
        let removed = try XCTUnwrap(timeline.firstIndex(of: Self.statusItemRemoved))
        let firstQuitStop = try XCTUnwrap(timeline.firstIndex { $0.contains("reason=quit") })
        XCTAssertLessThan(removed, firstQuitStop)
        XCTAssertEqual(timeline.filter { $0.hasPrefix("quit lifecycle-stops ") }.count, 1)
        XCTAssertFalse(timeline.contains(Self.terminationProceeds), "terminating now needs no later reply")

        quit.applicationWillTerminate()
        harness.settle()
        XCTAssertEqual(
            lines(harness, after: before).filter { $0.hasPrefix("quit lifecycle-stops ") }.count,
            1,
            "applicationWillTerminate does not tear down again"
        )
    }

    func testASecondQuitDuringTheDeferralChangesNothing() {
        let harness = AudioStateHarness(systemOutputMonitoring: true)
        defer { harness.tearDown() }
        harness.launchAndRelease()
        harness.moveDefaultOutput(to: AudioStateHarness.usbOutput)
        harness.poll()
        let quit = coordinator(for: harness)
        let before = harness.hal.timeline.count

        XCTAssertEqual(quit.applicationShouldTerminate(), .later)
        harness.advance(by: 2)
        harness.settle()
        XCTAssertEqual(quit.applicationShouldTerminate(), .later)
        harness.advance(by: 0.9)
        harness.settle()
        XCTAssertFalse(
            lines(harness, after: before).contains { $0.hasPrefix("quit lifecycle-stops ") },
            "the second request did not move the teardown earlier"
        )
        harness.advance(by: 0.2)
        harness.settle()
        quit.applicationWillTerminate()
        harness.settle()

        let timeline = lines(harness, after: before)
        XCTAssertEqual(timeline.filter { $0.hasPrefix("quit-deferred ") }, ["quit-deferred release-in=3.00 gen=-"])
        XCTAssertEqual(timeline.filter { $0 == Self.statusItemRemoved }.count, 1)
        XCTAssertEqual(timeline.filter { $0.hasPrefix("quit lifecycle-stops ") }.count, 1)
        XCTAssertEqual(timeline.filter { $0 == Self.terminationProceeds }.count, 1)
    }

    func testAnOutstandingPickerWriteDefersQuitForTheMaximum() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launchAndRelease()
        harness.holds.hold { point, _ in
            if case .defaultDeviceWrite = point {
                return true
            }
            return false
        }
        harness.state.selectOutputDevice(AudioStateHarness.usbOutput)
        harness.settle()
        // The window's settle period has passed, but the write has not
        // completed: the default is still to move.
        harness.advance(by: LifecycleQuietWindow.settle + 0.5)
        let quit = coordinator(for: harness)
        let calls = harness.hal.calls.count
        let before = harness.hal.timeline.count

        XCTAssertEqual(quit.applicationShouldTerminate(), .later)
        XCTAssertEqual(lines(harness, after: before).first, "quit-deferred release-in=3.00 gen=-")

        harness.advance(by: 2.9)
        harness.settle()
        XCTAssertFalse(lines(harness, after: before).contains { $0.hasPrefix("quit lifecycle-stops ") })
        harness.advance(by: 0.2)
        harness.settle()
        XCTAssertTrue(
            lines(harness, after: before).contains { $0.hasPrefix("quit lifecycle-stops completed=true") },
            "the write does not hold Quit past the maximum"
        )

        // The write completes after the teardown and issues nothing.
        let afterTeardown = harness.hal.calls.count
        harness.holds.releaseAll()
        harness.settle()
        XCTAssertEqual(harness.lifecycleCalls(after: afterTeardown), [])
        XCTAssertTrue(harness.lifecycleCalls(after: calls).contains(.destroyIOProc(AudioStateHarness.builtInMicrophone)))
    }

    func testAGenerationTheMainThreadHasNotSeenDefersQuitAsAFreshHold() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launchAndRelease()
        // The listener advances the generation on its own queue; its report
        // has not reached the main thread.
        harness.fireSystemNotification(.defaultInput)
        let quit = coordinator(for: harness)
        let before = harness.hal.timeline.count

        XCTAssertEqual(quit.applicationShouldTerminate(), .later)

        XCTAssertEqual(
            Array(lines(harness, after: before).prefix(2)),
            [
                "quiet-window hold reason=generation-advanced release-in=3.00 gen=\(lastGeneration(harness))",
                "quit-deferred release-in=3.00 gen=-"
            ]
        )
    }

    func testAChangeCarriedPastTheWindowsCapStillDefersQuit() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launchAndRelease()
        // Default-device notifications every 2 s keep the window armed up to
        // its cap, with the polls applying in between.
        for step in 0...7 {
            harness.fireSystemNotification(.defaultOutput)
            harness.settle()
            if step < 7 {
                harness.advance(by: 2)
                harness.poll()
            }
        }
        // Past the cap: the next change is carried, and the release waits for
        // a poll issued after the window's end, which has not been issued.
        harness.advance(by: 1.5)
        harness.fireSystemNotification(.defaultOutput)
        harness.settle()
        XCTAssertEqual(harness.lines(withPrefix: "quiet-window hold reason=hal-notification ").last.flatMap {
            AudioStateHarness.field("release-in", of: $0)
        }, "0.00", "the change is carried")
        let quit = coordinator(for: harness)
        let before = harness.hal.timeline.count

        XCTAssertEqual(quit.applicationShouldTerminate(), .later, "a change 0 s old defers Quit")
        XCTAssertEqual(lines(harness, after: before).first, "quit-deferred release-in=3.00 gen=-")

        harness.advance(by: 2.9)
        harness.settle()
        XCTAssertFalse(lines(harness, after: before).contains { $0.contains("reason=quit") })
        harness.advance(by: 0.2)
        harness.settle()
        XCTAssertTrue(lines(harness, after: before).contains { $0.hasPrefix("quit lifecycle-stops completed=true") })
    }

    func testATerminationThatNeverAskedTearsDownOnce() {
        let harness = AudioStateHarness()
        defer { harness.tearDown() }
        harness.launchAndRelease()
        let quit = coordinator(for: harness)
        let before = harness.hal.timeline.count

        quit.applicationWillTerminate()
        harness.settle()
        XCTAssertEqual(quit.applicationShouldTerminate(), .now)
        quit.applicationWillTerminate()
        harness.settle()

        let timeline = lines(harness, after: before)
        XCTAssertEqual(timeline.filter { $0 == Self.statusItemRemoved }.count, 1)
        XCTAssertEqual(timeline.filter { $0.hasPrefix("quit lifecycle-stops ") }.count, 1)
        XCTAssertFalse(timeline.contains { $0.hasPrefix("quit-deferred ") })
    }

    // MARK: Helpers

    private func coordinator(for harness: AudioStateHarness) -> QuitCoordinator {
        let state: AudioState = harness.state
        let hal = harness.hal
        return QuitCoordinator(
            scheduler: harness.scheduler,
            requestQuit: { state.requestQuit() },
            remainingDeferral: { state.remainingQuitDeferral() },
            removeStatusItem: { hal.noteLine(Self.statusItemRemoved) },
            tearDown: { state.stop() },
            letTerminationProceed: { hal.noteLine(Self.terminationProceeds) }
        )
    }

    private func lines(_ harness: AudioStateHarness, after count: Int) -> [String] {
        harness.hal.timeline.dropFirst(count).compactMap { entry in
            if case let .line(text) = entry {
                return text
            }
            return nil
        }
    }

    private func lastGeneration(_ harness: AudioStateHarness) -> String {
        harness.lines(withPrefix: "quiet-window hold ").last.flatMap { AudioStateHarness.field("gen", of: $0) } ?? "?"
    }
}
