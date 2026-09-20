import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// The reclaimer's wiring to `TapReclaimPlan` and the HAL seam, with a
/// substituted inventory. Nothing here reaches coreaudiod.
final class OrphanedProcessTapReclaimerTests: XCTestCase {
    private let publishedUID = PublicProcessedMicrophoneDevice.aggregateDeviceUID

    private func tap(
        _ objectID: AudioObjectID,
        _ uid: String,
        _ ownership: AudioResourceOwnership?
    ) -> AudioResourceInventory.ProcessTap {
        AudioResourceInventory.ProcessTap(
            objectID: objectID,
            uid: uid,
            name: "tap",
            ownership: ownership,
            bundleIDs: [],
            attributionIsAuthoritative: true,
            restoresAcrossReboot: false,
            targets: []
        )
    }

    private func aggregate(
        _ uid: String,
        _ ownership: AudioResourceOwnership,
        taps: [String]?,
        running: Bool
    ) -> AudioResourceInventory.AggregateDevice {
        AudioResourceInventory.AggregateDevice(
            objectID: 900,
            uid: uid,
            name: "aggregate",
            ownership: ownership,
            isRunningSomewhere: running,
            tapUIDs: taps
        )
    }

    private func inventory(
        taps: [AudioResourceInventory.ProcessTap],
        aggregates: [AudioResourceInventory.AggregateDevice],
        others: [String] = []
    ) -> OrphanedProcessTapReclaimer.Inventory {
        OrphanedProcessTapReclaimer.Inventory(
            otherRunningInstances: { others },
            processTaps: { taps },
            aggregateDevices: { aggregates }
        )
    }

    func testTheTapUnderAnEarlierPublicationStillInUseIsNotDestroyed() {
        let hal = FakeHALLifecycleCalls()
        let outcome = OrphanedProcessTapReclaimer.reclaim(
            scope: .everyTapOfThisApp,
            reason: "launch",
            generation: 7,
            halCalls: hal,
            inventory: inventory(
                taps: [tap(301, "published-tap", .publishedMicrophone), tap(302, "meter-tap", .systemOutputMeter)],
                aggregates: [aggregate(publishedUID, .publishedMicrophone, taps: ["published-tap"], running: true)]
            )
        )

        XCTAssertEqual(hal.lifecycleCalls, [])
        XCTAssertEqual(outcome.destroyedUIDs, [])
        XCTAssertEqual(Set(outcome.heldBackUIDs), ["published-tap", "meter-tap"])
    }

    func testStrandedTapsAreDestroyedThroughTheSeamAndListedTapsAreKept() {
        let hal = FakeHALLifecycleCalls()
        let outcome = OrphanedProcessTapReclaimer.reclaim(
            scope: .everyTapOfThisApp,
            reason: "launch",
            generation: 7,
            halCalls: hal,
            inventory: inventory(
                taps: [
                    tap(301, "published-tap", .publishedMicrophone),
                    tap(302, "listed-tap", .systemOutputMeter),
                    tap(303, "foreign-tap", nil)
                ],
                aggregates: [aggregate("user", .foreign, taps: ["listed-tap"], running: false)]
            )
        )

        XCTAssertEqual(hal.lifecycleCalls, [.destroyProcessTap(301)])
        XCTAssertEqual(outcome.candidateUIDs, ["published-tap", "listed-tap"])
        XCTAssertEqual(outcome.destroyedUIDs, ["published-tap"])
        XCTAssertEqual(outcome.heldBackUIDs, ["listed-tap"])
    }

    func testNothingIsReadOrDestroyedWhileAnotherInstanceRuns() {
        let hal = FakeHALLifecycleCalls()
        var aggregatesRead = false
        let outcome = OrphanedProcessTapReclaimer.reclaim(
            scope: .everyTapOfThisApp,
            reason: "launch",
            generation: 7,
            halCalls: hal,
            inventory: OrphanedProcessTapReclaimer.Inventory(
                otherRunningInstances: { ["io.github.yuhkis.audio-level-bar"] },
                processTaps: { [self.tap(301, "published-tap", .publishedMicrophone)] },
                aggregateDevices: {
                    aggregatesRead = true
                    return []
                }
            )
        )

        XCTAssertEqual(outcome.skip, .anotherInstanceRunning(["io.github.yuhkis.audio-level-bar"]))
        XCTAssertFalse(aggregatesRead)
        XCTAssertEqual(hal.lifecycleCalls, [])
    }

    func testThePublishedScopeLeavesTheSystemPlaybackMeterAlone() {
        let hal = FakeHALLifecycleCalls()
        let outcome = OrphanedProcessTapReclaimer.reclaim(
            scope: .publishedMicrophoneTaps,
            reason: "launch",
            generation: 7,
            halCalls: hal,
            inventory: inventory(
                taps: [tap(301, "published-tap", .publishedMicrophone), tap(302, "own-meter-tap", .systemOutputMeter)],
                aggregates: [
                    aggregate("io.github.yuhkis.audio-level-bar.tap.run", .systemOutputMeter, taps: ["own-meter-tap"], running: true)
                ]
            )
        )

        XCTAssertEqual(hal.lifecycleCalls, [.destroyProcessTap(301)])
        XCTAssertEqual(outcome.candidateUIDs, ["published-tap"])
        XCTAssertEqual(outcome.destroyedUIDs, ["published-tap"])
    }

    func testNothingIsDestroyedWhenTheAggregateDevicesCannotBeRead() {
        for scope in [TapReclaimScope.everyTapOfThisApp, .publishedMicrophoneTaps] {
            let hal = FakeHALLifecycleCalls()
            let outcome = OrphanedProcessTapReclaimer.reclaim(
                scope: scope,
                reason: "reclaim-command",
                generation: nil,
                halCalls: hal,
                inventory: OrphanedProcessTapReclaimer.Inventory(
                    otherRunningInstances: { [] },
                    processTaps: {
                        [self.tap(301, "published-tap", .publishedMicrophone), self.tap(302, "meter-tap", .systemOutputMeter)]
                    },
                    aggregateDevices: { nil }
                )
            )

            XCTAssertEqual(hal.lifecycleCalls, [], "a consumer may still record through a published device that could not be read")
            XCTAssertEqual(outcome.destroyedUIDs, [])
            XCTAssertTrue(outcome.aggregatesUnread)
            XCTAssertEqual(outcome.heldBackUIDs, outcome.candidateUIDs)
            XCTAssertFalse(outcome.candidateUIDs.isEmpty)
        }
    }

    func testEachDestroyIsBetweenItsBeginAndResultLines() {
        for (reason, generation, field) in [("launch", UInt64(7), "7"), ("reclaim-command", nil, "-")] {
            let hal = FakeHALLifecycleCalls()
            HALLifecycleLog.observer = { [hal] line in hal.noteLine(line) }
            defer { HALLifecycleLog.observer = nil }
            _ = OrphanedProcessTapReclaimer.reclaim(
                scope: .everyTapOfThisApp,
                reason: reason,
                generation: generation,
                halCalls: hal,
                inventory: inventory(taps: [tap(301, "published-tap", .publishedMicrophone)], aggregates: [])
            )

            XCTAssertEqual(hal.timeline, [
                .line("reclaimed-tap destroy-begin id=301 transport=- gen=\(field) reason=\(reason) tap-uid=published-tap"),
                .call(.destroyProcessTap(301)),
                .line("reclaimed-tap destroy id=301 transport=- status=0 gen=\(field) reason=\(reason) tap-uid=published-tap")
            ])
        }
    }

    func testTheSurveyDestroysNothing() {
        let outcome = OrphanedProcessTapReclaimer.survey(
            inventory: inventory(taps: [tap(301, "published-tap", .publishedMicrophone)], aggregates: [])
        )

        XCTAssertEqual(outcome.candidateUIDs, ["published-tap"])
        XCTAssertEqual(outcome.destroyedUIDs, [])
        XCTAssertEqual(outcome.heldBackUIDs, [])
    }
}
