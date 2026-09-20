import XCTest
@testable import AudioLevelBarCore

final class LaunchPlanTests: XCTestCase {
    func testLaunchArmsTheQuietWindowBeforeAnythingElse() {
        XCTAssertEqual(LaunchPlan.steps.first, .armQuietWindow)
        XCTAssertEqual(LaunchPlan.steps.filter { $0 == .armQuietWindow }.count, 1)
    }

    func testEveryStepThatCanStartSomethingComesAfterTheWindowArms() throws {
        let steps = LaunchPlan.steps
        let arm = try XCTUnwrap(steps.firstIndex(of: .armQuietWindow))
        for step in [
            LaunchPlan.Step.checkMicrophonePermission,
            .requestSystemOutputMeter,
            .startPolling
        ] {
            XCTAssertLessThan(arm, try XCTUnwrap(steps.firstIndex(of: step)), "\(step)")
        }
    }

    func testSystemNotificationsAreListenedForRightAfterTheWindowArms() throws {
        let steps = LaunchPlan.steps
        let listen = try XCTUnwrap(steps.firstIndex(of: .listenForSystemNotifications))

        XCTAssertEqual(listen, 1, "a default change during the rest of launch re-arms the window")
        for step in steps.dropFirst(listen + 1) {
            XCTAssertNotEqual(step, .armQuietWindow)
        }
    }

    func testLaunchItselfDestroysNothing() {
        XCTAssertEqual(
            LaunchPlan.steps,
            [
                .armQuietWindow,
                .listenForSystemNotifications,
                .readDevicesAndControls,
                .checkMicrophonePermission,
                .requestSystemOutputMeter,
                .startPolling
            ],
            "an earlier run's leftovers are removed at the first release that admits starts, not inside the launch window"
        )
    }

    func testTheWindowArmedAtLaunchHoldsUntilAPollAfterItsEnd() {
        // Launch arms at 10. The first poll's topology arms nothing, so the
        // launch window alone holds the first evaluations.
        var window = LifecycleQuietWindow()
        window.noteChange(at: 10)

        XCTAssertEqual(
            window.admission(at: 10.01, freshestSnapshotIssuedAt: nil, outstandingDefaultWrites: 0),
            .hold,
            "the evaluation inside launch starts nothing"
        )
        XCTAssertEqual(
            window.admission(at: 13.1, freshestSnapshotIssuedAt: 12.9, outstandingDefaultWrites: 0),
            .hold,
            "no poll issued after the window's end has applied"
        )
        XCTAssertEqual(
            window.admission(at: 13.3, freshestSnapshotIssuedAt: 13.1, outstandingDefaultWrites: 0),
            .full
        )
    }
}
