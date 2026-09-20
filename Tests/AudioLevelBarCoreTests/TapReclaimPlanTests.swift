import XCTest
@testable import AudioLevelBarCore

final class TapReclaimPlanTests: XCTestCase {
    private let publishedUID = "io.github.yuhkis.audio-level-bar.processed-microphone.public"
    private let meterAggregateUID = "io.github.yuhkis.audio-level-bar.tap.run"

    private let publishedTap = ReclaimableTap(uid: "published-tap", ownership: .publishedMicrophone)
    private let legacyTap = ReclaimableTap(uid: "legacy-tap", ownership: .legacyPublishedMicrophone)
    private let meterTap = ReclaimableTap(uid: "meter-tap", ownership: .systemOutputMeter)
    private let foreignTap = ReclaimableTap(uid: "foreign-tap", ownership: .foreign)

    private func publication(taps: [String]? = ["published-tap"], running: Bool) -> ExistingAggregate {
        ExistingAggregate(uid: publishedUID, ownership: .publishedMicrophone, tapUIDs: taps, isRunningSomewhere: running)
    }

    private func reclaimable(
        _ taps: [ReclaimableTap],
        _ aggregates: [ExistingAggregate],
        scope: TapReclaimScope = .everyTapOfThisApp
    ) -> [String] {
        TapReclaimPlan.reclaimable(taps: taps, aggregates: aggregates, scope: scope)
    }

    func testTapsReferencedByAnExistingAggregateAreNotReclaimed() {
        let userAggregate = ExistingAggregate(
            uid: "user",
            ownership: .foreign,
            tapUIDs: ["meter-tap"],
            isRunningSomewhere: false
        )
        XCTAssertEqual(reclaimable([meterTap, legacyTap], [userAggregate]), ["legacy-tap"])
    }

    func testNothingIsReclaimedWhileAStalePublishedAggregateIsInUse() {
        XCTAssertEqual(reclaimable([publishedTap, legacyTap, meterTap], [publication(running: true)]), [])
        XCTAssertEqual(
            reclaimable([publishedTap, meterTap], [publication(taps: [], running: true)]),
            [],
            "a running aggregate of this app holds everything back, whatever it lists"
        )
    }

    func testPublishedTapsWaitForTheStaleAggregateToDisappear() {
        XCTAssertEqual(
            reclaimable([publishedTap, legacyTap], [publication(taps: [], running: false)]),
            [],
            "an idle publication still exists, and its tap list may not show everything it uses"
        )
    }

    func testTapsAreReclaimedOnceTheStaleAggregateIsGone() {
        XCTAssertEqual(reclaimable([publishedTap, legacyTap, meterTap], []), ["published-tap", "legacy-tap", "meter-tap"])
    }

    func testUnrelatedStrandedTapsAreStillReclaimed() {
        XCTAssertEqual(
            reclaimable([publishedTap, meterTap], [publication(running: false)]),
            ["meter-tap"],
            "a system playback meter tap is not under the earlier publication"
        )
    }

    func testAnotherAppsTapIsNeverReclaimed() {
        XCTAssertEqual(reclaimable([foreignTap], []), [])
        XCTAssertEqual(reclaimable([foreignTap], [], scope: .publishedMicrophoneTaps), [])
    }

    func testAnUnreadableTapListReclaimsNothing() {
        let unreadable = ExistingAggregate(uid: "user", ownership: .foreign, tapUIDs: nil, isRunningSomewhere: false)
        XCTAssertEqual(reclaimable([meterTap, publishedTap], [unreadable]), [])
    }

    func testARunningAggregateOfThisAppHoldsBackEveryTapAtLaunch() {
        let meterAggregate = ExistingAggregate(
            uid: meterAggregateUID,
            ownership: .systemOutputMeter,
            tapUIDs: ["meter-tap"],
            isRunningSomewhere: true
        )
        XCTAssertEqual(reclaimable([publishedTap, legacyTap], [meterAggregate]), [])

        let foreignRunning = ExistingAggregate(uid: "user", ownership: .foreign, tapUIDs: [], isRunningSomewhere: true)
        XCTAssertEqual(
            reclaimable([legacyTap], [foreignRunning]),
            ["legacy-tap"],
            "another app's running aggregate that lists none of these taps does not"
        )
    }

    func testThePublishedScopeReclaimsOnlyPublishedTapsBesideTheInstancesOwnMeter() {
        let ownMeter = ExistingAggregate(
            uid: meterAggregateUID,
            ownership: .systemOutputMeter,
            tapUIDs: ["meter-tap"],
            isRunningSomewhere: true
        )
        let strandedMeterTap = ReclaimableTap(uid: "earlier-meter-tap", ownership: .systemOutputMeter)

        XCTAssertEqual(
            reclaimable([publishedTap, legacyTap, meterTap, strandedMeterTap], [ownMeter], scope: .publishedMicrophoneTaps),
            ["published-tap", "legacy-tap"],
            "the running instance's own private meter aggregate does not hold the published taps back, and no meter tap is touched"
        )
        XCTAssertEqual(
            reclaimable([publishedTap], [ownMeter, publication(running: false)], scope: .publishedMicrophoneTaps),
            [],
            "an earlier publication still holds its taps back in this scope too"
        )
        let runningPublication = publication(taps: [], running: true)
        XCTAssertEqual(reclaimable([legacyTap], [runningPublication], scope: .publishedMicrophoneTaps), [])
    }
}
