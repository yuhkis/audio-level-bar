import XCTest
@testable import AudioLevelBarCore

final class EvaluationPlanTests: XCTestCase {
    func testOrdinaryEvaluationOutsideAWindow() {
        XCTAssertEqual(
            EvaluationPlan.steps(admission: .full, windowArmed: false, launchCleanupOwed: false),
            [
                .updateProcessedMicrophoneState,
                .retryDisabledProcessedMicrophoneTeardown,
                .performProcessedMicrophonePlan,
                .evaluateMicrophoneMeter,
                .publishMicrophoneDisplay,
                .publishProcessedMicrophone,
                .applySystemOutputIntent
            ]
        )
    }

    func testPublicationIsNeverAttemptedWhileStartsAreHeld() {
        for admission in [LifecycleQuietWindow.Admission.hold, .stopsOnly] {
            for armed in [false, true] {
                for owed in [false, true] {
                    XCTAssertFalse(
                        EvaluationPlan.steps(admission: admission, windowArmed: armed, launchCleanupOwed: owed)
                            .contains(.publishProcessedMicrophone),
                        "\(admission), armed \(armed), cleanup owed \(owed)"
                    )
                }
            }
        }
    }

    func testHoldingEvaluationOnlyFollowsTheTarget() {
        let steps = EvaluationPlan.steps(admission: .hold, windowArmed: true, launchCleanupOwed: true)

        XCTAssertFalse(steps.contains(.applySystemOutputIntent))
        XCTAssertFalse(steps.contains(.retryDisabledProcessedMicrophoneTeardown))
        XCTAssertFalse(steps.contains(.noteRelease))
        XCTAssertFalse(steps.contains(.takeRelease))
        XCTAssertFalse(steps.contains(.cleanUpAfterEarlierRun))
        XCTAssertEqual(
            steps,
            [
                .updateProcessedMicrophoneState,
                .performProcessedMicrophonePlan,
                .evaluateMicrophoneMeter,
                .publishMicrophoneDisplay
            ],
            "while holding, the display follows the target and the plans see the hold"
        )
    }

    func testStopsOnlyReleaseIssuesStopsAndOwedTeardownsAndTakesTheRelease() {
        let steps = EvaluationPlan.steps(admission: .stopsOnly, windowArmed: true, launchCleanupOwed: false)

        XCTAssertEqual(steps.first, .noteRelease)
        XCTAssertEqual(steps.last, .takeRelease)
        XCTAssertEqual(
            steps,
            [
                .noteRelease,
                .updateProcessedMicrophoneState,
                .retryDisabledProcessedMicrophoneTeardown,
                .performProcessedMicrophonePlan,
                .evaluateMicrophoneMeter,
                .publishMicrophoneDisplay,
                .applySystemOutputIntent,
                .takeRelease
            ],
            "the plans, the meter and the system playback step see the admission and only stop"
        )
    }

    func testReleaseEvaluationActsBeforeTheCarriedWindowHolds() {
        let steps = EvaluationPlan.steps(admission: .full, windowArmed: true, launchCleanupOwed: false)

        XCTAssertEqual(steps.first, .noteRelease)
        XCTAssertEqual(steps.last, .takeRelease)
        XCTAssertEqual(
            Array(steps.dropFirst().dropLast()),
            EvaluationPlan.steps(admission: .full, windowArmed: false, launchCleanupOwed: false),
            "the full release evaluation acts exactly as an ordinary one"
        )
    }

    func testProcessedMicrophoneGoesBeforeTheMeterAndPublicationBeforeSystemOutput() throws {
        let steps = EvaluationPlan.steps(admission: .full, windowArmed: false, launchCleanupOwed: false)
        let plan = try XCTUnwrap(steps.firstIndex(of: .performProcessedMicrophonePlan))
        let meter = try XCTUnwrap(steps.firstIndex(of: .evaluateMicrophoneMeter))
        let publication = try XCTUnwrap(steps.firstIndex(of: .publishProcessedMicrophone))
        let systemOutput = try XCTUnwrap(steps.firstIndex(of: .applySystemOutputIntent))

        XCTAssertLessThan(plan, meter)
        XCTAssertLessThan(meter, publication, "publication waits for the meter's IO")
        XCTAssertLessThan(publication, systemOutput, "publication rebuilds the system playback meter itself")
    }

    // MARK: Launch cleanup

    func testTheLaunchCleanupRunsOnlyAtAReleaseThatAdmitsStartsWhileItIsOwed() {
        for admission in [LifecycleQuietWindow.Admission.hold, .stopsOnly] {
            for armed in [false, true] {
                XCTAssertFalse(
                    EvaluationPlan.steps(admission: admission, windowArmed: armed, launchCleanupOwed: true)
                        .contains(.cleanUpAfterEarlierRun),
                    "\(admission), armed \(armed): nothing is destroyed inside a window or at a stops-only release"
                )
            }
        }
        XCTAssertTrue(
            EvaluationPlan.steps(admission: .full, windowArmed: true, launchCleanupOwed: true)
                .contains(.cleanUpAfterEarlierRun)
        )
        XCTAssertFalse(
            EvaluationPlan.steps(admission: .full, windowArmed: true, launchCleanupOwed: false)
                .contains(.cleanUpAfterEarlierRun),
            "once it has run, it does not run again"
        )
    }

    func testTheLaunchCleanupGoesBeforeAnythingTheEvaluationBuildsOrStops() {
        XCTAssertEqual(
            EvaluationPlan.steps(admission: .full, windowArmed: true, launchCleanupOwed: true),
            [
                .noteRelease,
                .cleanUpAfterEarlierRun,
                .updateProcessedMicrophoneState,
                .retryDisabledProcessedMicrophoneTeardown,
                .performProcessedMicrophonePlan,
                .evaluateMicrophoneMeter,
                .publishMicrophoneDisplay,
                .publishProcessedMicrophone,
                .applySystemOutputIntent,
                .takeRelease
            ]
        )
    }
}
